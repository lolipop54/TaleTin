//! 书内 CSS 的持久格式。条件在读章时求值，导入时保存全部分支。
use super::parser::{Declaration, Rule, SheetItem, SheetRuleParser, Stylesheet};
use super::{conditions::Environment, layers::Layers, resources, selector};
use cssparser::{Parser, StyleSheetParser, ToCss};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};

#[derive(Serialize, Deserialize)]
pub(super) struct Sheet {
    path: Arc<str>,
    resources: Vec<String>,
    nodes: Vec<Node>,
}

#[derive(Serialize, Deserialize)]
enum Node {
    Style {
        selector: String,
        declarations: Vec<Declaration>,
        #[serde(skip)]
        compiled: OnceLock<selectors::parser::SelectorList<selector::CssSelectorImpl>>,
    },
    Condition(String, String, Vec<Node>),
    Layer(String, Option<Vec<Node>>),
    Import(String, Option<String>, String),
    Font(Option<Value>),
    Other(String),
    Invalid,
}

impl Sheet {
    pub(super) fn parse(path: &str, text: &str) -> (Self, Vec<String>) {
        let mut imports = Vec::new();
        let path: Arc<str> = path.into();
        let nodes = parse_nodes(&path, text.trim_start_matches('\u{feff}'), &mut imports);
        let mut resources: Vec<_> = resources::rewrite(text, &path).1.into_iter().collect();
        resources.sort_unstable();
        (
            Self {
                path,
                resources,
                nodes,
            },
            imports,
        )
    }
}

fn parse_nodes(path: &Arc<str>, text: &str, imports: &mut Vec<String>) -> Vec<Node> {
    let mut parser = Parser::new(text);
    let mut rules = SheetRuleParser {
        index: 0,
        path: path.clone(),
    };
    StyleSheetParser::new(&mut parser, &mut rules)
        .map(|item| match item {
            Ok(SheetItem::Rule(rule)) => Node::Style {
                selector: rule.selectors.to_css_string(),
                declarations: rule.declarations,
                compiled: OnceLock::new(),
            },
            Ok(SheetItem::Conditional(kind, test, body)) => {
                Node::Condition(kind, test, parse_nodes(path, &body, imports))
            }
            Ok(SheetItem::Layer(name, body)) => {
                Node::Layer(name, body.map(|b| parse_nodes(path, &b, imports)))
            }
            Ok(SheetItem::Import(raw)) => {
                let Some((target, tail)) = super::parser::import_target(&raw) else {
                    return Node::Invalid;
                };
                let Some((layer, media)) = super::layers::import_layer(&tail) else {
                    return Node::Invalid;
                };
                let Some(target) = resources::local_entry(&target, path) else {
                    return Node::Invalid;
                };
                imports.push(target.clone());
                Node::Import(target, layer, media)
            }
            Ok(SheetItem::FontFace(face)) => Node::Font(face),
            Ok(SheetItem::AtRule(name)) => Node::Other(name),
            Err(_) => Node::Invalid,
        })
        .collect()
}

pub(super) type References = Vec<(String, String)>;
pub(super) type ConditionChecks = Vec<(String, String, bool)>;

pub(super) fn activate(
    sheets: &HashMap<String, Sheet>,
    refs: &References,
    env: &Environment,
) -> Result<(Stylesheet, ConditionChecks), String> {
    let mut state = Activation {
        sheets,
        env,
        layers: Layers::default(),
        stack: HashSet::new(),
        output: Stylesheet::default(),
        checks: Vec::new(),
    };
    for (source, (id, media)) in refs.iter().enumerate() {
        // link[media] 在旧入口相当于包在外面的 @media，未命中的资源也要登记。
        let Some(sheet) = sheets.get(id) else {
            continue;
        };
        state
            .output
            .resources
            .extend(sheet.resources.iter().cloned());
        if state.enabled("media", media) {
            state.visit(id, &[], source)?;
        }
    }
    Ok((state.output, state.checks))
}

struct Activation<'a> {
    sheets: &'a HashMap<String, Sheet>,
    env: &'a Environment,
    layers: Layers,
    stack: HashSet<String>,
    output: Stylesheet,
    checks: ConditionChecks,
}

impl Activation<'_> {
    fn enabled(&mut self, kind: &str, expression: &str) -> bool {
        if expression.is_empty() && kind == "media" {
            return true;
        }
        self.output.at_rules.push(kind.into());
        self.check(kind, expression)
    }
    fn check(&mut self, kind: &str, expression: &str) -> bool {
        if let Some((_, _, matched)) = self
            .checks
            .iter()
            .find(|(k, e, _)| k == kind && e == expression)
        {
            return *matched;
        }
        let matched = self.env.matches(kind, expression);
        self.checks
            .push((kind.to_owned(), expression.to_owned(), matched));
        matched
    }
    fn visit(&mut self, id: &str, layer: &[String], source: usize) -> Result<(), String> {
        let Some(sheet) = self.sheets.get(id) else {
            self.output.skipped_rules += 1;
            return Ok(());
        };
        if !self.stack.insert(id.to_owned()) {
            return Ok(());
        }
        self.output
            .resources
            .extend(sheet.resources.iter().cloned());
        self.walk(&sheet.nodes, &sheet.path, layer, source)?;
        self.stack.remove(id);
        Ok(())
    }
    fn walk(
        &mut self,
        nodes: &[Node],
        path: &Arc<str>,
        layer: &[String],
        source: usize,
    ) -> Result<(), String> {
        for node in nodes {
            match node {
                Node::Style {
                    selector: text,
                    compiled,
                    declarations,
                } => {
                    if compiled.get().is_none() {
                        #[cfg(test)]
                        let start = std::time::Instant::now();
                        let list = selector::parse_selector_list(&mut Parser::new(text))
                            .map_err(|_| format!("无法恢复 {path} 的选择器 {text}"))?;
                        let _ = compiled.set(list);
                        #[cfg(test)]
                        super::publication_tests::note_compile(start.elapsed().as_nanos());
                    }
                    self.output.rules.push(Rule {
                        selectors: compiled.get().unwrap().clone(),
                        declarations: declarations.clone(),
                        path: path.clone(),
                        source,
                        layer: self.layers.rank(layer),
                        order: self.output.rules.len() as u32,
                    });
                }
                Node::Condition(kind, test, children) => {
                    self.output.at_rules.push(kind.clone());
                    if self.check(kind, test) {
                        self.walk(children, path, layer, source)?;
                    }
                }
                Node::Layer(name, Some(children)) => {
                    if let Some(child) = self.layers.name(layer, name) {
                        self.walk(children, path, &child, source)?;
                    } else {
                        self.output.skipped_rules += 1;
                    }
                }
                Node::Layer(names, None) => {
                    for name in super::value::split_top_level(names, ',') {
                        if self.layers.name(layer, name.trim()).is_none() {
                            self.output.skipped_rules += 1;
                        }
                    }
                }
                Node::Import(id, name, media) => {
                    let next = match name {
                        Some(name) => match self.layers.name(layer, name) {
                            Some(next) => next,
                            None => continue,
                        },
                        None => layer.to_vec(),
                    };
                    if self.enabled("media", media) && !self.stack.contains(id) {
                        if self.sheets.contains_key(id) {
                            self.output.imported_files += 1;
                        }
                        self.visit(id, &next, 0)?;
                    }
                }
                Node::Font(face) => self.output.font_faces.extend(face.clone()),
                Node::Other(kind) => self.output.at_rules.push(kind.clone()),
                Node::Invalid => self.output.skipped_rules += 1,
            }
        }
        Ok(())
    }
}
