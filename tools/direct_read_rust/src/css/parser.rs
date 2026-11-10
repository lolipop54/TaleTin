// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 统一的 CSS 语法入口：一份样式表（外部文件、章节 `<style>` 或行内 `style`）
//! 都用同一个 tokenizer 和声明解析器，不再在 Dart、Rust 各写一遍 `split(';')`。
//!
//! 规则按真实来源顺序保留；每次 `@import` 都在引用位置展开，当前引用链阻止循环。
//! `@media`／`@supports` 保留条件块，由实际纸面环境求值后递归收集命中的规则。

use std::collections::HashMap;

use cssparser::{
    AtRuleParser, CowRcStr, DeclarationParser, ParseError, Parser, ParserState,
    QualifiedRuleParser, RuleBodyItemParser, RuleBodyParser, StyleSheetParser, Token,
};

use super::conditions::Environment;
use super::selector::{CssSelectorImpl, parse_selector_list};
use selectors::parser::SelectorList;

#[derive(Clone, Debug)]
pub struct StyleSource {
    /// 章节条目路径或 CSS 文件路径；行内 `<style>` 用所属章节路径。
    pub path: String,
    pub text: String,
    /// 行内 `<style>` 没有独立文件，`@import` 仍相对所属章节解析。
    pub inline: bool,
}

#[derive(Clone, Debug)]
pub struct Declaration {
    pub name: String,
    pub value: String,
    pub important: bool,
}

#[derive(Clone, Debug)]
pub struct Rule {
    pub layer: Vec<u32>,
    pub selectors: SelectorList<CssSelectorImpl>,
    pub declarations: Vec<Declaration>,
    pub order: u32,
    /// 规则来自第几个来源，诊断和缓存身份使用。
    pub source: usize,
}

#[derive(Debug, Default)]
pub struct Stylesheet {
    pub resources: std::collections::HashSet<String>,
    pub font_faces: Vec<serde_json::Value>,
    pub rules: Vec<Rule>,
    pub skipped_rules: usize,
    pub invalid_declarations: usize,
    pub imported_files: usize,
    pub at_rules: Vec<String>,
}

impl Stylesheet {
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }
}

/// 解析一组有序来源；`files` 是书内所有 CSS 文件（键是归档条目路径），
/// 供 `@import` 在同一遍解析里按位置展开。
pub fn parse_sources(sources: &[StyleSource], files: &HashMap<String, String>) -> Stylesheet {
    parse_sources_in(sources, files, &Environment::default())
}
pub(super) fn parse_sources_in(
    sources: &[StyleSource],
    files: &HashMap<String, String>,
    environment: &Environment,
) -> Stylesheet {
    let mut parser = SheetContext {
        files,
        environment,
        order: 0,
        sheet: Stylesheet::default(),
        stack: Vec::new(),
        layers: super::layers::Layers::default(),
        layer: Vec::new(),
    };
    for (index, source) in sources.iter().enumerate() {
        parser.stack.push(source.path.clone());
        parser.parse_one(index, &source.path, &source.text, source.inline);
        parser.stack.pop();
    }
    parser.sheet
}

struct SheetContext<'a> {
    layers: super::layers::Layers,
    layer: Vec<String>,
    environment: &'a Environment,
    files: &'a HashMap<String, String>,
    order: u32,
    sheet: Stylesheet,
    /// 当前 `@import` 链，防止 A→B→A。
    stack: Vec<String>,
}

impl<'a> SheetContext<'a> {
    fn parse_one(&mut self, index: usize, path: &str, text: &str, _inline: bool) {
        // 包括当前环境未命中的 @media；切换主题后所需资源也必须预备。
        self.sheet
            .resources
            .extend(super::resources::rewrite(text, path).1);
        let text = text.strip_prefix('\u{feff}').unwrap_or(text);
        let mut input = Parser::new(text);
        let mut rule_parser = SheetRuleParser {
            index,
            path: path.to_owned(),
        };
        let source_path = path.to_owned();
        for item in StyleSheetParser::new(&mut input, &mut rule_parser) {
            match item {
                Ok(SheetItem::Rule(rule)) => {
                    let order = self.order;
                    self.order += 1;
                    self.sheet.rules.push(Rule {
                        order,
                        layer: self.layers.rank(&self.layer),
                        ..rule
                    });
                }
                Ok(SheetItem::Import(import)) => {
                    self.parse_import(&source_path, &import);
                }
                Ok(SheetItem::Conditional(name, condition, body)) => {
                    self.sheet.at_rules.push(name.clone());
                    if self.environment.matches(&name, &condition) {
                        self.parse_one(index, path, &body, false);
                    }
                }
                Ok(SheetItem::AtRule(name)) => {
                    self.sheet.at_rules.push(name);
                }
                Ok(SheetItem::FontFace(face)) => {
                    self.sheet.font_faces.extend(face);
                }
                Ok(SheetItem::Layer(name, body)) => {
                    if let Some(body) = body {
                        if let Some(layer_path) = self.layers.name(&self.layer, &name) {
                            let previous = std::mem::replace(&mut self.layer, layer_path);
                            self.parse_one(index, path, &body, false);
                            self.layer = previous;
                        } else {
                            self.sheet.skipped_rules += 1;
                        }
                    } else {
                        for name in super::value::split_top_level(&name, ',') {
                            if self.layers.name(&self.layer, name.trim()).is_none() {
                                self.sheet.skipped_rules += 1;
                            }
                        }
                    }
                }
                Err(_) => self.sheet.skipped_rules += 1,
            }
        }
        // 每次引用都在原位置追加规则；只有当前导入链用于阻止循环。
        let _ = index;
    }

    fn parse_import(&mut self, from: &str, import: &str) {
        let Some((target, tail)) = import_target(import) else {
            self.sheet.skipped_rules += 1;
            return;
        };
        let Some((layer, media)) = super::layers::import_layer(&tail) else {
            return;
        };
        let previous = self.layer.clone();
        let imported_layer = if let Some(name) = layer {
            let Some(path) = self.layers.name(&self.layer, &name) else {
                return;
            };
            path
        } else {
            previous.clone()
        };
        if !media.is_empty() {
            self.sheet.at_rules.push("media".to_owned());
            if !self.environment.matches("media", &media) {
                return;
            }
        }
        let path = resolve_path(from, &target);
        let Some(text) = self.files.get(&path) else {
            self.sheet.skipped_rules += 1;
            return;
        };
        if self.stack.iter().any(|entry| entry == &path) {
            // 循环引用按 CSS 规则忽略这一条，不继续展开。
            return;
        }
        self.sheet.imported_files += 1;
        self.stack.push(path.clone());
        self.layer = imported_layer;
        self.parse_one(0, &path, text, false);
        self.layer = previous;
        self.stack.pop();
    }
}

enum SheetItem {
    Layer(String, Option<String>),
    Rule(Rule),
    Import(String),
    AtRule(String),
    FontFace(Option<serde_json::Value>),
    Conditional(String, String, String),
}

struct SheetRuleParser {
    index: usize,
    path: String,
}

impl<'i> AtRuleParser<'i> for SheetRuleParser {
    type Prelude = (String, String);
    type AtRule = SheetItem;
    type Error = selectors::parser::SelectorParseErrorKind;

    fn parse_prelude(
        &mut self,
        name: CowRcStr<'i>,
        input: &mut Parser<'i>,
    ) -> Result<Self::Prelude, ParseError<Self::Error>> {
        let start = input.state();
        while input.next_including_whitespace_and_comments().is_ok() {}
        Ok((
            name.to_ascii_lowercase(),
            input.slice_from(start.position()).trim().to_string(),
        ))
    }

    fn parse_block(
        &mut self,
        prelude: Self::Prelude,
        _start: &ParserState,
        input: &mut Parser<'i>,
    ) -> Result<Self::AtRule, ParseError<Self::Error>> {
        // 保留条件块原文，由包含实际纸面环境的上下文递归解析。
        // tokenizer 负责完整消费嵌套块，字符串里的花括号不会变成规则边界。
        let start = input.position();
        consume_remaining(input)?;
        if prelude.0 == "font-face" && prelude.1.is_empty() {
            Ok(SheetItem::FontFace(super::font_faces::declaration(
                input.slice_from(start),
                &self.path,
            )))
        } else if prelude.0 == "layer" {
            Ok(SheetItem::Layer(
                prelude.1,
                Some(input.slice_from(start).to_owned()),
            ))
        } else if matches!(prelude.0.as_str(), "media" | "supports") {
            Ok(SheetItem::Conditional(
                prelude.0,
                prelude.1,
                input.slice_from(start).to_owned(),
            ))
        } else {
            Ok(SheetItem::AtRule(prelude.0))
        }
    }

    fn rule_without_block(
        &mut self,
        prelude: Self::Prelude,
        _start: &ParserState,
    ) -> Result<Self::AtRule, ()> {
        if prelude.0.eq_ignore_ascii_case("import") {
            Ok(SheetItem::Import(prelude.1))
        } else if prelude.0 == "layer" {
            Ok(SheetItem::Layer(prelude.1, None))
        } else if prelude.0.eq_ignore_ascii_case("charset")
            || prelude.0.eq_ignore_ascii_case("namespace")
        {
            Ok(SheetItem::AtRule(prelude.0))
        } else {
            Err(())
        }
    }
}

impl<'i> QualifiedRuleParser<'i> for SheetRuleParser {
    type Prelude = SelectorList<CssSelectorImpl>;
    type QualifiedRule = SheetItem;
    type Error = selectors::parser::SelectorParseErrorKind;

    fn parse_prelude(
        &mut self,
        input: &mut Parser<'i>,
    ) -> Result<Self::Prelude, ParseError<Self::Error>> {
        parse_selector_list(input)
    }

    fn parse_block(
        &mut self,
        selectors: Self::Prelude,
        _start: &ParserState,
        input: &mut Parser<'i>,
    ) -> Result<Self::QualifiedRule, ParseError<Self::Error>> {
        let mut sink = DeclarationSink {
            declarations: Vec::new(),
            invalid: 0,
        };
        {
            let body = RuleBodyParser::new(input, &mut sink);
            for _ in body {}
        }
        if sink.declarations.is_empty() {
            return Err(ParseError::custom(
                selectors::parser::SelectorParseErrorKind::EmptySelector,
            ));
        }
        Ok(SheetItem::Rule(Rule {
            layer: Vec::new(),
            selectors,
            declarations: sink
                .declarations
                .into_iter()
                .map(|mut d| {
                    d.value = super::resources::rewrite(&d.value, &self.path).0;
                    d
                })
                .collect(),
            order: 0,
            source: self.index,
        }))
    }
}

struct DeclarationSink {
    declarations: Vec<Declaration>,
    invalid: usize,
}

impl<'i> DeclarationParser<'i> for DeclarationSink {
    type Declaration = Declaration;
    type Error = selectors::parser::SelectorParseErrorKind;

    fn parse_value(
        &mut self,
        name: CowRcStr<'i>,
        input: &mut Parser<'i>,
        _start: &ParserState,
    ) -> Result<Self::Declaration, ParseError<Self::Error>> {
        let value_start = input.position();
        let mut value_end = value_start;
        let mut important = false;
        loop {
            let state = input.state();
            match input.next_including_whitespace_and_comments() {
                Ok(Token::Delim('!')) => {
                    let save = input.state();
                    let is_important = input
                        .try_parse(|input| {
                            input.skip_whitespace();
                            input.expect_ident_matching("important")
                        })
                        .is_ok();
                    if is_important {
                        important = true;
                        break;
                    }
                    input.reset(&save);
                    value_end = input.position();
                }
                Ok(token) => {
                    let block = matches!(
                        token,
                        Token::Function(_)
                            | Token::ParenthesisBlock
                            | Token::SquareBracketBlock
                            | Token::CurlyBracketBlock
                    );
                    if block {
                        // `var(--x)`、`rgb(...)`、`url(...)` 的内容在嵌套块里；
                        // 必须整块消费，否则值只切到函数名，颜色/宽度都会丢。
                        consume_nested(input)?;
                    }
                    value_end = input.position();
                }
                Err(_) => break,
            }
            let _ = state;
        }
        let value = input.slice(value_start..value_end).trim().to_string();
        if value.is_empty() {
            self.invalid += 1;
            return Err(ParseError::custom(
                selectors::parser::SelectorParseErrorKind::EmptySelector,
            ));
        }
        let declaration = Declaration {
            name: if name.starts_with("--") {
                name.to_string()
            } else {
                name.to_ascii_lowercase()
            },
            value,
            important,
        };
        self.declarations.push(declaration.clone());
        Ok(declaration)
    }
}

impl<'i> QualifiedRuleParser<'i> for DeclarationSink {
    type Prelude = ();
    type QualifiedRule = Declaration;
    type Error = selectors::parser::SelectorParseErrorKind;
}

impl<'i> AtRuleParser<'i> for DeclarationSink {
    type Prelude = ();
    type AtRule = Declaration;
    type Error = selectors::parser::SelectorParseErrorKind;
}

impl<'i> RuleBodyItemParser<'i, Declaration, selectors::parser::SelectorParseErrorKind>
    for DeclarationSink
{
    fn parse_declarations(&self) -> bool {
        true
    }

    fn parse_qualified(&self) -> bool {
        false
    }
}

/// 只解析 `style="..."` 的声明列表，使用和样式表完全相同的声明解析器。
pub fn parse_inline_declarations(style: &str) -> Vec<Declaration> {
    let mut input = Parser::new(style);
    let mut sink = DeclarationSink {
        declarations: Vec::new(),
        invalid: 0,
    };
    {
        let body = RuleBodyParser::new(&mut input, &mut sink);
        for _ in body {}
    }
    sink.declarations
}

/// 递归消费一个刚打开的嵌套块（函数、括号、方括号、花括号）。
fn consume_nested(
    input: &mut Parser<'_>,
) -> Result<(), ParseError<selectors::parser::SelectorParseErrorKind>> {
    input.parse_nested_block(consume_remaining)
}

/// 把当前解析范围内的 token 全部消费掉；遇到嵌套块递归进入。
fn consume_remaining(
    input: &mut Parser<'_>,
) -> Result<(), ParseError<selectors::parser::SelectorParseErrorKind>> {
    while let Ok(token) = input.next_including_whitespace_and_comments() {
        let block = matches!(
            token,
            Token::Function(_)
                | Token::ParenthesisBlock
                | Token::SquareBracketBlock
                | Token::CurlyBracketBlock
        );
        if block {
            consume_nested(input)?;
        }
    }
    Ok(())
}

fn import_target(prelude: &str) -> Option<(String, String)> {
    let mut input = Parser::new(prelude);
    let target = input.expect_url_or_string().ok()?.to_string();
    let start = input.position();
    consume_remaining(&mut input).ok()?;
    Some((target, input.slice_from(start).trim().to_owned()))
}

/// 相对当前条目解析路径，处理 `./`／`../`，不访问文件系统。
pub fn resolve_path(from: &str, target: &str) -> String {
    if target.starts_with('/') {
        return target.trim_start_matches('/').to_owned();
    }
    let mut parts: Vec<&str> = from.split('/').collect();
    parts.pop();
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            value => parts.push(value),
        }
    }
    parts.join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files() -> HashMap<String, String> {
        let mut files = HashMap::new();
        files.insert(
            "OEBPS/imported.css".to_owned(),
            "p { color: red; }".to_owned(),
        );
        files
    }

    #[test]
    fn keeps_source_order_across_rules() {
        let sources = vec![
            StyleSource {
                path: "OEBPS/ch1.xhtml".to_owned(),
                text: "p { color: blue; }".to_owned(),
                inline: true,
            },
            StyleSource {
                path: "OEBPS/ch1.xhtml".to_owned(),
                text: "@import url(imported.css); p { color: green; }".to_owned(),
                inline: true,
            },
        ];
        let sheet = parse_sources(&sources, &files());
        let colors: Vec<&str> = sheet
            .rules
            .iter()
            .filter_map(|rule| {
                rule.declarations
                    .iter()
                    .find(|d| d.name == "color")
                    .map(|d| d.value.as_str())
            })
            .collect();
        // @import 在当前来源位置展开：blue → red → green
        assert_eq!(colors, vec!["blue", "red", "green"]);
        assert_eq!(sheet.imported_files, 1);
    }

    #[test]
    fn keeps_values_with_semicolons_in_strings() {
        let sources = vec![StyleSource {
            path: "a.xhtml".to_owned(),
            text: r#"p { content: "a;b"; color: red; }"#.to_owned(),
            inline: true,
        }];
        let sheet = parse_sources(&sources, &HashMap::new());
        assert_eq!(sheet.rules.len(), 1);
        assert_eq!(sheet.rules[0].declarations.len(), 2);
        assert_eq!(sheet.rules[0].declarations[0].value, "\"a;b\"");
    }

    #[test]
    fn inline_custom_property_is_kept() {
        let declarations = parse_inline_declarations("--x: #ff0000; color: var(--x);");
        assert_eq!(declarations.len(), 2);
        assert_eq!(declarations[0].name, "--x");
        assert_eq!(declarations[0].value, "#ff0000");
        assert_eq!(declarations[1].value, "var(--x)");
    }

    #[test]
    fn media_is_recorded_not_applied() {
        let sources = vec![StyleSource {
            path: "a.xhtml".to_owned(),
            text: "@media print { p { color: black; } } p { color: blue; }".to_owned(),
            inline: true,
        }];
        let sheet = parse_sources(&sources, &HashMap::new());
        assert_eq!(sheet.rules.len(), 1);
        assert_eq!(sheet.at_rules, vec!["media".to_owned()]);
    }
}
