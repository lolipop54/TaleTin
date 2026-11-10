// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 层叠、继承、变量和属性映射。
//!
//! 顺序固定为：标签默认（只取会影响文字语义的标签）→ 作者样式表（选择器匹配、
//! 特异性、important、来源顺序）→ 行内样式；可继承属性按父元素计算值传递；
//! `var()` 在当前元素的自定义属性作用域内替换，绝不提升为全书变量。

use std::collections::HashMap;

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
    pub invalid_declarations: usize,
    pub unknown_properties: HashMap<String, u32>,
    pub skipped_rules: usize,
}

pub struct Engine {
    sheet: Stylesheet,
    document_path: String,
    reader_font: f64,
    has_legacy_font_sizes: bool,
    pub diagnostics: Diagnostics,
}

impl Engine {
    /// 只有元数据里带 `cssSources`（按章节真实顺序）时才启用新引擎。
    /// 旧缓存或旧测试没有它时返回 None，调用方继续走旧路径。
    pub fn from_metadata(metadata: &Value) -> Option<Self> {
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
        let sheet = parse_sources_in(
            &sources,
            &files,
            &super::conditions::Environment::from_json(&metadata["cssEnvironment"]),
        );
        let diagnostics = Diagnostics {
            skipped_rules: sheet.skipped_rules,
            ..Default::default()
        };
        Some(Self {
            sheet,
            diagnostics,
            document_path: metadata["documentPath"].as_str().unwrap_or("").to_owned(),
            reader_font: super::conditions::Environment::from_json(&metadata["cssEnvironment"])
                .font,
            has_legacy_font_sizes: false,
        })
    }

    pub fn resources(&self) -> Vec<&String> {
        self.sheet.resources.iter().collect()
    }

    pub fn font_faces(&self) -> &[Value] {
        &self.sheet.font_faces
    }

    pub fn needs_environment(&self) -> bool {
        self.has_legacy_font_sizes
            || self
                .sheet
                .at_rules
                .iter()
                .any(|name| matches!(name.as_str(), "media" | "supports"))
    }
    pub fn is_empty(&self) -> bool {
        self.sheet.is_empty()
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

        // 1. 标签默认：只取旧转换器真正处理过的语义标签，块级间距/字号仍由阅读器
        //    和 Dart 排版层负责，避免同一条规则被两处相乘。
        for (name, value) in tag_defaults(crate::dom::tag(element.handle())) {
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
        if let Some(size) = super::presentation::font_size(element.handle(), self.reader_font) {
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

        for (name, value) in super::presentation::hints(element.handle()) {
            push_declaration(&mut declarations, &mut custom, name, value,
                false, false, 0, 0, 0, &[], true);
        }

        // 2. 作者样式表：只把真正命中的规则参与排序；命中元素后按特异性取最高。
        for rule in &self.sheet.rules {
            let Some(specificity) = matches_selector_list(&rule.selectors, element) else {
                continue;
            };
            push_rule(
                &mut declarations,
                &mut custom,
                &mut extras,
                rule,
                specificity,
            );
        }

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
                        self.sheet.resources.extend(paths);
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
            for (property, value) in expand_declaration(&name, value) {
                let wide = matches!(
                    value.as_str(),
                    "inherit" | "initial" | "unset" | "revert" | "revert-layer"
                );
                // 静态无效值从不进入层叠；含 var 的声明若计算时无效，按 unset 处理，
                // 而不能退回较早声明（CSS 的计算值阶段失效语义）。
                let valid =
                    wide || parse_property(&mut Computed::default(), &property, &value, None, 1.0);
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
            match value.as_str() {
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
        if !extras.is_empty() {
            computed.extras = extras;
        }

        if let Some(mode) = computed.font_weight_relative.take() {
            let base = parent.and_then(|p| p.font_weight).unwrap_or(400) as i32;
            computed.font_weight =
                Some((base + if mode == "bolder" { 300 } else { -300 }).clamp(100, 900) as u16);
        }
        // rem 根字号仍是阅读器正文字号，html 不再额外缩放它。body 的相对字号
        // 必须进入继承链：转换型电子书常用 body 放大、段落缩小来恢复正文大小，
        // 只清掉 body 会留下半套倍率。绝对 px/pt 继续由显示层忽略。
        let tag = crate::dom::tag(element.handle());
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
            rule.order,
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
/// 展开简写。`border` 这类会重置未写子属性的简写必须在这里一次性展开，
/// 不能留给后面的长写「碰巧覆盖」。
fn canonical_name(name: &str) -> String {
    if name.trim().starts_with("--") {
        return name.trim().to_owned();
    }
    let lower = name.trim().to_ascii_lowercase();
    match lower.as_str() {
        "duokan-text-indent" | "-webkit-text-indent" => "text-indent".to_owned(),
        "duokan-text-align" => "text-align".to_owned(),
        "-webkit-text-size-adjust" | "-ms-text-size-adjust" => "text-size-adjust".to_owned(),
        "-webkit-user-select" | "-moz-user-select" | "-ms-user-select" | "-khtml-user-select" => {
            "user-select".to_owned()
        }
        "word-wrap" => "overflow-wrap".to_owned(),
        "overflow-x" | "overflow-y" => "overflow".to_owned(),
        "page-break-before" => "break-before".to_owned(),
        "page-break-after" => "break-after".to_owned(),
        "page-break-inside" => "break-inside".to_owned(),
        _ => lower,
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

fn tag_defaults(tag: &str) -> Vec<(&'static str, &'static str)> {
    match tag {
        // hr 的默认盒子与 Dart 共用生成表，避免两端各写一份边框和外边距。
        "hr" => crate::style_tables_generated::tag_defaults("hr")
            .iter()
            .map(|decl| (decl.name, decl.value))
            .collect(),
        "a" => vec![("text-decoration", "underline")],
        "b" | "strong" => vec![("font-weight", "bold")],
        "i" | "em" => vec![("font-style", "italic")],
        "u" | "ins" => vec![("text-decoration", "underline")],
        "s" | "del" | "strike" => vec![("text-decoration", "line-through")],
        "small" => vec![("font-size", "0.85em")],
        "sup" => vec![("vertical-align", "super")],
        "sub" => vec![("vertical-align", "sub")],
        "center" => vec![("text-align", "center")],
        "figcaption" => vec![("text-align", "center")],
        "pre" => vec![("white-space", "pre")],
        _ => vec![],
    }
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
