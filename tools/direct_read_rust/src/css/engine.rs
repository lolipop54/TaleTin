// Copyright (c) 2026 GT Reader contributors. GPL-3.0-only, see LICENSE.
//! 层叠、继承、变量和属性映射。
//!
//! 顺序固定为：标签默认（只取会影响文字语义的标签）→ 作者样式表（选择器匹配、
//! 特异性、important、来源顺序）→ 行内样式；可继承属性按父元素计算值传递；
//! `var()` 在当前元素的自定义属性作用域内替换，绝不提升为全书变量。

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use serde_json::Value;

use super::parser::{Rule, StyleSource, Stylesheet, parse_sources_in};
use super::selector::{ElementRef, matches_selector_list};
use super::style::Computed;
use super::value::Decoration;

use super::inheritance::*;
use super::properties::parse_property;
use super::shorthand::expand_declaration;
use super::variables::{resolve_custom_properties, substitute_vars};

use super::cascade::{Candidate, winner};

#[derive(Debug, Default)]
pub struct Diagnostics {
    pub matched_elements: usize,
    pub attempted_selectors: usize,
    pub matched_rules: usize,
    pub setup_us: u128,
    pub match_ns: u128,
    pub cascade_ns: u128,
    // 仅测试时核对每个元素所有命中规则，包括被后来声明覆盖的规则。
    pub hits: Option<Vec<(usize, u32, u32)>>,
    pub invalid_declarations: usize,
    pub unknown_properties: HashMap<String, u32>,
    pub skipped_rules: usize,
}

pub struct Engine {
    active: Arc<super::publication::Active>,
    indexed: bool,
    profile: bool,
    candidates: Vec<(usize, usize)>,
    inline_resources: HashSet<String>,
    legacy_mobi: bool,
    font_bases: Option<HashMap<usize, i32>>,
    table_hints: HashMap<usize, super::presentation::Hints>,
    link_color: Option<String>,
    link_states: [Option<super::value::Color>; 2],
    document_path: String,
    reader_font: f64,
    has_legacy_font_sizes: bool,
    trace_element: Option<String>,
    pub trace: Option<Value>,
    pub diagnostics: Diagnostics,
}

impl Engine {
    /// 新 EPUB 按书和章取规则，早期章节缓存和其他格式沿用原样式来源。
    pub fn from_metadata(metadata: &Value) -> Option<Self> {
        let profile = metadata["cssDiagnostics"] == true;
        let start = profile.then(std::time::Instant::now);
        let env = super::conditions::Environment::from_json(&metadata["cssEnvironment"]);
        let path = metadata["documentPath"].as_str().unwrap_or("");
        let (active, indexed) = if let Some(digest) = metadata["cssBook"].as_str() {
            let indexed = metadata["cssFullScan"] != true;
            (
                super::publication::for_chapter(digest, path, &env, indexed).ok()?,
                indexed,
            )
        } else {
            (
                Arc::new(super::publication::Active::new(
                    Self::legacy_sheet(metadata, &env)?,
                    false,
                )),
                false,
            )
        };
        let diagnostics = Diagnostics {
            skipped_rules: active.sheet.skipped_rules,
            setup_us: start.map_or(0, |t| t.elapsed().as_micros()),
            hits: (metadata["cssCompareHits"] == true).then(Vec::new),
            ..Default::default()
        };
        Some(Self {
            active,
            indexed,
            profile,
            candidates: Vec::new(),
            inline_resources: HashSet::new(),
            legacy_mobi: metadata["legacyMobi"] == true,
            font_bases: None,
            table_hints: HashMap::new(),
            link_color: None,
            link_states: [None, None],
            diagnostics,
            document_path: path.to_owned(),
            reader_font: env.font,
            has_legacy_font_sizes: false,
            trace_element: metadata["cssTraceElement"].as_str().map(str::to_owned),
            trace: None,
        })
    }

    fn legacy_sheet(
        metadata: &Value,
        environment: &super::conditions::Environment,
    ) -> Option<Stylesheet> {
        let unified = metadata
            .get("unifiedCss")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let empty = Vec::new();
        let raw_sources: &[Value] = match metadata.get("cssSources").and_then(Value::as_array) {
            Some(sources) => sources.as_slice(),
            None if unified => empty.as_slice(),
            None => return None,
        };
        let mut sources = Vec::new();
        for item in raw_sources {
            let path = item.get("path")?.as_str()?.to_owned();
            let text = item.get("text")?.as_str()?.to_owned();
            let inline = item.get("inline").and_then(Value::as_bool).unwrap_or(false);
            sources.push(StyleSource { path, text, inline });
        }
        let mut files = HashMap::new();
        if let Some(map) = metadata.get("cssFiles").and_then(Value::as_object) {
            for (path, text) in map {
                if let Some(text) = text.as_str() {
                    files.insert(path.clone(), text.to_owned());
                }
            }
        }
        Some(parse_sources_in(&sources, &files, environment))
    }

    pub fn resources(&self) -> Vec<&String> {
        self.active
            .sheet
            .resources
            .union(&self.inline_resources)
            .collect()
    }

    pub fn font_faces(&self) -> &[Value] {
        &self.active.sheet.font_faces
    }

    pub fn needs_environment(&self) -> bool {
        self.has_legacy_font_sizes
            || self
                .active
                .sheet
                .at_rules
                .iter()
                .any(|name| matches!(name.as_str(), "media" | "supports"))
    }
    pub fn is_empty(&self) -> bool {
        self.active.sheet.is_empty()
    }

    /// 计算一个元素的作者样式。`parent` 是父元素的计算结果；返回时带上本元素的
    /// 自定义属性表，供子元素继承。
    pub fn compute(
        &mut self,
        element: &ElementRef,
        parent: Option<&Computed>,
        parent_vars: &HashMap<String, String>,
    ) -> (Computed, HashMap<String, String>) {
        self.diagnostics.matched_elements += 1;
        let mut declarations: Vec<(String, Candidate)> = Vec::new();
        let mut custom: HashMap<String, Vec<Candidate>> = HashMap::new();
        let mut extras = HashMap::new();
        let mut trace = self.trace_element.as_deref().and_then(|target| {
            ["data-gt-id", "id"]
                .into_iter()
                .any(|name| crate::dom::attr(element.handle(), name).as_deref() == Some(target))
                .then(|| serde_json::json!({"element": target, "winners": {}, "invalid": []}))
        });

        // 1. 标签默认：只取旧转换器真正处理过的语义标签，块级间距/字号仍由阅读器
        //    和 Dart 排版层负责，避免同一条规则被两处相乘。
        let tag = crate::dom::tag(element.handle());
        let legacy_default = match tag {
            "nobr" => Some(("white-space", "nowrap")),
            "tt" => Some(("font-family", "monospace")),
            _ => None,
        };
        let fieldset: &[(&str, &str)] = match tag {
            "fieldset" => &[
                ("display", "block"),
                ("border", "2px groove currentcolor"),
                ("padding", "0.35em 0.75em 0.625em"),
            ],
            "legend" => &[("display", "block")],
            _ => &[],
        };
        for (name, value) in tag_defaults(tag)
            .chain(legacy_default)
            .chain(fieldset.iter().copied())
        {
            push_declaration(
                &mut declarations,
                &mut custom,
                name,
                value.to_owned(),
                false,
                false,
                0,
                0,
                0,
                &[],
                false,
            );
        }

        // 旧 HTML 的 font[size] 位于作者样式表之前，优先级为零。
        if let Some(size) =
            super::presentation::font_size(element.handle(), self.reader_font, &mut self.font_bases)
        {
            // font[size] 的固定差值随读者字号换算，必须保留可重算的来源资料。
            self.has_legacy_font_sizes = true;
            push_declaration(
                &mut declarations,
                &mut custom,
                "font-size",
                size,
                false,
                false,
                0,
                0,
                0,
                &[],
                true,
            );
        }

        let node = element.handle();
        if tag == "table" {
            super::presentation_table::collect(node, &mut self.table_hints);
        }
        if tag == "body" {
            self.link_states = ["vlink", "alink"].map(|key| {
                crate::dom::attr(node, key)
                    .and_then(|s| super::presentation::color(&s))
                    .and_then(|s| super::value::parse_color(&s))
            });
            self.link_color =
                crate::dom::attr(node, "link").and_then(|v| super::presentation::color(&v));
        }
        let mut hints = self.table_hints.remove(&node.id).unwrap_or_default();
        // 旧容器会居中定宽的块。这里仍以表现提示进入层叠，子块写 margin 时可覆盖。
        if matches!(
            tag,
            "p" | "div"
                | "table"
                | "hr"
                | "pre"
                | "blockquote"
                | "fieldset"
                | "h1"
                | "h2"
                | "h3"
                | "h4"
                | "h5"
                | "h6"
        ) && parent.is_some_and(|p| p.text_align == Some("center"))
            && node.parent.borrow().upgrade().is_some_and(|p| {
                crate::dom::tag(&p) == "center"
                    || crate::dom::tag(&p) == "div"
                        && super::presentation::keyword(&p, "align") == "center"
            })
        {
            hints.push(("margin-left", "auto".into()));
            hints.push(("margin-right", "auto".into()));
        }
        if tag == "a"
            && crate::dom::attr(node, "href").is_some()
            && let Some(c) = &self.link_color
        {
            hints.push(("color", c.clone()));
        }
        hints.extend(super::presentation::hints(
            node,
            self.legacy_mobi,
            &self.document_path,
            &mut self.inline_resources,
        ));
        for (name, value) in hints {
            push_declaration(
                &mut declarations,
                &mut custom,
                name,
                value,
                false,
                false,
                0,
                0,
                0,
                &[],
                true,
            );
        }

        // 2. 作者样式表：只把真正命中的规则参与排序；命中元素后按特异性取最高。
        let match_start = self.profile.then(std::time::Instant::now);
        let rules = &self.active.sheet.rules;
        if self.indexed {
            self.active.index.candidates(element, &mut self.candidates);
            self.diagnostics.attempted_selectors += self.candidates.len();
            for group in self.candidates.chunk_by(|a, b| a.0 == b.0) {
                let rule = &rules[group[0].0];
                let branches = rule.selectors.slice();
                let best = super::selector::matching_specificity(
                    group.iter().map(|b| &branches[b.1]),
                    element,
                );
                if let Some(specificity) = best {
                    self.diagnostics.matched_rules += 1;
                    if let Some(hits) = &mut self.diagnostics.hits {
                        hits.push((element.handle().id, rule.order, specificity));
                    }
                    push_rule(
                        &mut declarations,
                        &mut custom,
                        &mut extras,
                        rule,
                        specificity,
                    );
                }
            }
        } else {
            for rule in rules {
                self.diagnostics.attempted_selectors += rule.selectors.slice().len();
                let Some(specificity) = matches_selector_list(&rule.selectors, element) else {
                    continue;
                };
                self.diagnostics.matched_rules += 1;
                if let Some(hits) = &mut self.diagnostics.hits {
                    hits.push((element.handle().id, rule.order, specificity));
                }
                push_rule(
                    &mut declarations,
                    &mut custom,
                    &mut extras,
                    rule,
                    specificity,
                );
            }
        }

        let cascade_start = match_start.map(|start| {
            self.diagnostics.match_ns += start.elapsed().as_nanos();
            std::time::Instant::now()
        });
        // 3. 行内样式：同一套声明解析器，选择器特异性最高，但仍然低于作者 important。
        if let Some(style) = crate::dom::attr(element.handle(), "style") {
            for (index, declaration) in super::parser::parse_inline_declarations(&style)
                .into_iter()
                .enumerate()
            {
                push_declaration(
                    &mut declarations,
                    &mut custom,
                    &declaration.name,
                    {
                        let (value, paths) =
                            super::resources::rewrite(&declaration.value, &self.document_path);
                        self.inline_resources.extend(paths);
                        value
                    },
                    declaration.important,
                    true,
                    u32::MAX,
                    u32::MAX,
                    index as u32,
                    &[],
                    true,
                );
            }
        }

        // 变量先按本元素依赖关系求值；简写保留原 token 到这一步，不能提前丢掉 var()。
        let raw_custom = custom
            .into_iter()
            .filter_map(|(k, v)| winner(&v).map(|c| (k, c.value.clone())))
            .collect();
        let vars = resolve_custom_properties(&raw_custom, parent_vars);
        let mut specified: HashMap<String, Vec<Candidate>> = HashMap::new();
        for (name, candidate) in declarations {
            let variable = candidate.value.contains("var(");
            let value = substitute_vars(&candidate.value, &vars);
            let value = value.as_deref().unwrap_or("unset");
            // 旧属性 page-break-before/after:always 对应现代属性的 page。
            // 等 var() 替换结束再映射；现代 break-before 不接受旧关键字。
            let (name, value) = match name.as_str() {
                "page-break-before" => ("break-before", legacy_page_break(value)),
                "page-break-after" => ("break-after", legacy_page_break(value)),
                _ => (name.as_str(), value),
            };
            for (property, value) in expand_declaration(name, value) {
                let wide = matches!(
                    value.as_str(),
                    "inherit" | "initial" | "unset" | "revert" | "revert-layer"
                );
                // 静态无效值从不进入层叠；含 var 的声明若计算时无效，按 unset 处理，
                // 而不能退回较早声明（CSS 的计算值阶段失效语义）。
                let valid =
                    wide || parse_property(&mut Computed::default(), &property, &value, None, 1.0);
                if (!valid || (variable && value == "unset"))
                    && let Some(trace) = &mut trace
                {
                    trace["invalid"]
                        .as_array_mut()
                        .unwrap()
                        .push(serde_json::json!({
                            "property": property,
                            "value": value,
                            "fallback": if variable { "unset" } else { "discard" },
                        }));
                }
                if !valid && !variable {
                    continue;
                }
                let mut next = candidate.clone();
                next.value = if valid { value } else { "unset".to_owned() };
                specified.entry(property).or_default().push(next);
            }
        }
        let parent_size = parent
            .and_then(|value| value.font_size_factor)
            .unwrap_or(1.0);
        let mut computed = Computed::default();
        // 先继承，再应用胜出的声明。initial 必须能清掉继承值，不能当作“没写”。
        inherit_missing(&mut computed, parent, parent_size);
        // 普通/访问/按下共用同一层叠位置。子元素的作者字色可单独覆盖。
        let colored = specified
            .get("color")
            .and_then(|c| winner(c))
            .is_some_and(|c| {
                c.author && (c.inline || c.order > 0 || tag != "a") && c.value != "inherit"
            });
        if !colored {
            let (visited, active) = if tag == "a" && crate::dom::attr(node, "href").is_some() {
                (self.link_states[0].clone(), self.link_states[1].clone())
            } else {
                (
                    parent.and_then(|p| p.visited_ink.clone()),
                    parent.and_then(|p| p.active_ink.clone()),
                )
            };
            computed.visited_ink = visited;
            computed.active_ink = active;
        }
        computed.language = crate::dom::attr(node, "xml:lang")
            .or_else(|| crate::dom::attr(node, "lang"))
            .or_else(|| parent.and_then(|p| p.language.clone()));
        // HTML 行组默认居中，不沿用整张表或更外层元素的 vertical-align。
        if matches!(tag, "thead" | "tbody" | "tfoot") {
            computed.vertical_align = None;
        }
        computed.font_size_declared = specified
            .get("font-size")
            .and_then(|values| winner(values))
            .is_some();
        let mut keys: Vec<&String> = specified.keys().collect();
        keys.sort();
        for name in keys {
            let Some(candidate) = winner(&specified[name]) else {
                continue;
            };
            let value = &candidate.value;
            if let Some(trace) = &mut trace {
                let (origin, path) = if !candidate.author {
                    ("tagDefault", None)
                } else if candidate.inline {
                    ("inline", Some(self.document_path.as_str()))
                } else if candidate.order == 0 {
                    ("presentationHint", Some(self.document_path.as_str()))
                } else {
                    let rule = &self.active.sheet.rules[(candidate.order - 1) as usize];
                    ("stylesheet", Some(rule.path.as_ref()))
                };
                trace["winners"][name] = serde_json::json!({
                    "value": value, "origin": origin, "path": path,
                    "important": candidate.important, "specificity": candidate.specificity,
                    "order": candidate.order,
                });
            }
            match value.as_str() {
                "initial" | "unset"
                    if name == "vertical-align"
                        && matches!(tag, "td" | "th" | "tr" | "thead" | "tbody" | "tfoot") =>
                {
                    parse_property(&mut computed, name, "baseline", parent, parent_size);
                }
                "initial" => reset_property(&mut computed, name),
                "inherit" => copy_property(&mut computed, parent, name),
                "unset" | "revert" | "revert-layer" => {
                    if INHERITED.contains(&name.as_str()) {
                        copy_property(&mut computed, parent, name);
                    } else {
                        reset_property(&mut computed, name);
                    }
                }
                _ => {
                    if !parse_property(&mut computed, name, value, parent, parent_size) {
                        self.diagnostics.invalid_declarations += 1;
                    }
                }
            }
        }
        computed.extras.extend(extras);
        // 普通块本身不会成为行内上下标。保留行内容器向子片段传播以及表格的垂直对齐。
        if matches!(computed.vertical_align.as_deref(), Some("sub" | "super"))
            && match computed.display {
                Some(display) => {
                    matches!(display, "block" | "flowRoot" | "listItem" | "flex" | "grid")
                }
                None => matches!(
                    tag,
                    "p" | "div"
                        | "blockquote"
                        | "section"
                        | "article"
                        | "h1"
                        | "h2"
                        | "h3"
                        | "h4"
                        | "h5"
                        | "h6"
                        | "body"
                        | "li"
                        | "pre"
                ),
            }
        {
            computed.vertical_align = None;
        }

        if let Some(mode) = computed.font_weight_relative.take() {
            let base = parent.and_then(|p| p.font_weight).unwrap_or(400) as i32;
            computed.font_weight =
                Some((base + if mode == "bolder" { 300 } else { -300 }).clamp(100, 900) as u16);
        }
        // rem 根字号仍是阅读器正文字号，html 不再额外缩放它。body 的相对字号
        // 必须进入继承链：转换型电子书常用 body 放大、段落缩小来恢复正文大小，
        // 只清掉 body 会留下半套倍率。绝对 px/pt 继续由显示层忽略。
        if tag == "html" {
            computed.font_size = None;
            computed.font_size_factor = None;
        }
        // Chromium 的 hr 对 currentColor 边框使用专门的浅灰凹边绘色，
        // 即使作者把 color 设为黑色也一样；显式 border-color 仍按作者颜色。
        if tag == "hr" {
            for side in &mut computed.border {
                if matches!(side.color, Some(super::value::Color::Current))
                    && matches!(side.style.as_deref(), Some("inset" | "outset"))
                {
                    side.color = Some(super::value::Color::Argb(0xffeeeeee));
                }
            }
        }
        // 只写 border-width 不会自动产生四条实线；CSS 初始线型为 none。
        // 只写线型时则使用 medium 宽度和元素当前字色。
        for side in &mut computed.border {
            if side.width.is_some() || side.style.is_some() || side.color.is_some() {
                side.style.get_or_insert_with(|| "none".to_owned());
                side.width.get_or_insert(super::value::Length::Px(3.0));
                side.color.get_or_insert(super::value::Color::Current);
            }
        }
        resolve_current_color(&mut computed, parent);
        if let Some(decoration) = computed.decoration.as_ref() {
            if decoration.lines.is_empty()
                && decoration.color.is_none()
                && decoration.style.is_none()
                && decoration.thickness.is_none()
            {
                // 明确写 text-decoration:none：保留空记录，用来取消链接默认下划线。
                computed.decoration = Some(Decoration {
                    lines: vec![],
                    color: None,
                    style: None,
                    thickness: None,
                });
            }
        }
        if let Some(trace) = trace {
            self.trace = Some(trace);
        }
        if let Some(start) = cascade_start {
            self.diagnostics.cascade_ns += start.elapsed().as_nanos();
        }
        (computed, vars)
    }
}

fn push_rule(
    specified: &mut Vec<(String, Candidate)>,
    custom: &mut HashMap<String, Vec<Candidate>>,
    extras: &mut HashMap<String, String>,
    rule: &Rule,
    specificity: u32,
) {
    for (index, declaration) in rule.declarations.iter().enumerate() {
        push_declaration(
            specified,
            custom,
            &declaration.name,
            declaration.value.clone(),
            declaration.important,
            false,
            specificity,
            // 表现提示占顺序 0；即使第一条样式是通配符，也要排在提示之后。
            rule.order + 1,
            index as u32,
            &rule.layer,
            true,
        );
        if !known_property(&declaration.name) && !declaration.name.starts_with("--") {
            extras.insert(declaration.name.clone(), declaration.value.clone());
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn push_declaration(
    specified: &mut Vec<(String, Candidate)>,
    custom: &mut HashMap<String, Vec<Candidate>>,
    name: &str,
    value: String,
    important: bool,
    inline: bool,
    specificity: u32,
    order: u32,
    index: u32,
    layer: &[u32],
    author: bool,
) {
    let name = canonical_name(name);
    let candidate = Candidate {
        value,
        important,
        inline,
        specificity,
        order,
        index,
        layer: layer.to_vec(),
        author,
    };
    if name.starts_with("--") {
        custom.entry(name).or_default().push(candidate);
    } else {
        specified.push((name, candidate));
    }
}
/// 使用与 Dart 相同的属性别名表，CSS 自定义属性名保留大小写。
fn canonical_name(name: &str) -> String {
    if name.trim().starts_with("--") {
        return name.trim().to_owned();
    }
    let lower = name.trim().to_ascii_lowercase();
    if matches!(lower.as_str(), "page-break-before" | "page-break-after") {
        return lower;
    }
    crate::style_tables_generated::alias_target(&lower)
        .map(str::to_owned)
        .unwrap_or(lower)
}

fn legacy_page_break(value: &str) -> &str {
    if value.eq_ignore_ascii_case("always") {
        "page"
    } else {
        value
    }
}

fn known_property(name: &str) -> bool {
    crate::style_tables_generated::STYLE_PROPERTIES
        .iter()
        .any(|property| property.name == name)
        || matches!(
            name,
            "margin"
                | "padding"
                | "border"
                | "border-top"
                | "border-right"
                | "border-bottom"
                | "border-left"
                | "border-width"
                | "border-style"
                | "border-color"
                | "background"
                | "font"
                | "list-style"
                | "text-decoration"
        )
}

fn tag_defaults(tag: &str) -> impl Iterator<Item = (&'static str, &'static str)> {
    // 只迁移原先确实参与层叠的默认值。其余表项由 Dart 的显示角色和
    // 测量读取，或等待核对；提前在这里启用会叠加标题、列表、上标的默认样式。
    let property = match tag {
        "a" | "u" | "ins" | "s" | "del" | "strike" => "text-decoration",
        "b" | "strong" => "font-weight",
        "i" | "em" => "font-style",
        "big" | "small" => "font-size",
        "sup" | "sub" => "vertical-align",
        "center" | "caption" | "figcaption" => "text-align",
        "pre" => "white-space",
        "hr" => "*",
        "table" => "box-sizing",
        "thead" => "break-inside",
        _ => "",
    };
    let declarations = if property.is_empty() {
        &[]
    } else {
        crate::style_tables_generated::tag_defaults(tag)
    };
    declarations
        .iter()
        .filter(move |decl| property == "*" || decl.name == property)
        .map(|decl| (decl.name, decl.value))
}

pub struct StyleCache {
    pub styles: HashMap<usize, Computed>,
    pub vars: HashMap<usize, HashMap<String, String>>,
}

impl StyleCache {
    pub fn new() -> Self {
        Self {
            styles: HashMap::new(),
            vars: HashMap::new(),
        }
    }
}

impl Default for StyleCache {
    fn default() -> Self {
        Self::new()
    }
}
