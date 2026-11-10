// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
// Book stylesheet matching for the simplified layout.
//
// The stylesheet is parsed once at import time by Dart into a whitelisted,
// pre-normalized rule list. This module only deserializes those rules, matches
// them against an element (tag / class / id / simple descendant selectors) and
// merges the declarations with the same cascade rules as the Dart reference
// implementation. No CSS source text is parsed here.
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Default)]
pub struct SelectorPart {
    tag: Option<String>,
    id: Option<String>,
    classes: Vec<String>,
}

impl SelectorPart {
    fn matches(&self, tag: &str, id: Option<&str>, classes: &[String]) -> bool {
        if let Some(expected) = &self.tag {
            if expected != tag {
                return false;
            }
        }
        if let Some(expected) = &self.id {
            if Some(expected.as_str()) != id {
                return false;
            }
        }
        for name in &self.classes {
            if !classes.iter().any(|c| c == name) {
                return false;
            }
        }
        true
    }
}

#[derive(Clone, Default)]
pub struct Border {
    pub width: i32,
    pub style: i32,
    pub color: u32,
}

#[derive(Clone, Default)]
pub struct Props {
    pub align: Option<i32>,
    pub indent: Option<i32>,
    pub weight: Option<i32>,
    pub italic: Option<i32>,
    pub size: Option<f64>,
    pub color: Option<u32>,
    pub background: Option<u32>,
    /// 顺序：上、右、下、左
    pub borders: [Option<Border>; 4],
    pub radius: [i64; 4],
    pub has_radius: bool,
    pub shadow: Option<[i64; 4]>,
    pub padding: [i64; 4],
    pub has_padding: bool,
    /// 四边外边距，顺序上、右、下、左，单位是百分之一 em（与 padding 同一口径）。
    /// 这一版只有上、下参与块流；左外边距仍由 Dart 折进左内边距（历史做法），不重复计算。
    pub margins: Option<Vec<i64>>,
    pub list_style: Option<i32>,
    pub pre: bool,
    pub text_shadow: Option<[i64; 4]>,
    /// 文字装饰：0 无、1 下划线、2 删除线、3 两者都有
    pub decoration: Option<i32>,
    /// 字距／词距：相对字号的百分之一 em，可为负；None 表示没写
    pub letter_spacing: Option<i64>,
    pub word_spacing: Option<i64>,
    /// 显式宽度／最大宽度 `[数值(单位的 1/100), 单位]`；
    /// 单位 1 百分比、2 em、3 px。目前只有图片使用。
    pub width: Option<[i64; 2]>,
    pub max_width: Option<[i64; 2]>,
}

impl Props {
    pub fn is_empty(&self) -> bool {
        self.align.is_none()
            && self.indent.is_none()
            && self.weight.is_none()
            && self.italic.is_none()
            && self.size.is_none()
            && self.color.is_none()
            && self.background.is_none()
            && self.borders.iter().all(|side| side.is_none())
            && !self.has_radius
            && self.shadow.is_none()
            && !self.has_padding
            && self.margins.is_none()
            && self.list_style.is_none()
            && !self.pre
            && self.text_shadow.is_none()
            && self.decoration.is_none()
            && self.letter_spacing.is_none()
            && self.word_spacing.is_none()
            && self.width.is_none()
            && self.max_width.is_none()
    }

    /// 用 self 覆盖 base（self 优先级更高）。
    pub fn merge_over(&self, base: &Props) -> Props {
        let mut borders: [Option<Border>; 4] = Default::default();
        for i in 0..4 {
            borders[i] = self.borders[i].clone().or_else(|| base.borders[i].clone());
        }
        let padding = if self.has_padding {
            self.padding
        } else {
            base.padding
        };
        Props {
            align: self.align.or(base.align),
            indent: self.indent.or(base.indent),
            weight: self.weight.or(base.weight),
            italic: self.italic.or(base.italic),
            size: self.size.or(base.size),
            color: self.color.or(base.color),
            background: self.background.or(base.background),
            borders,
            radius: if self.has_radius {
                self.radius
            } else {
                base.radius
            },
            has_radius: self.has_radius || base.has_radius,
            shadow: self.shadow.or(base.shadow),
            padding,
            has_padding: self.has_padding || base.has_padding,
            margins: self.margins.clone().or_else(|| base.margins.clone()),
            list_style: self.list_style.or(base.list_style),
            pre: self.pre || base.pre,
            text_shadow: self.text_shadow.or(base.text_shadow),
            decoration: self.decoration.or(base.decoration),
            letter_spacing: self.letter_spacing.or(base.letter_spacing),
            word_spacing: self.word_spacing.or(base.word_spacing),
            width: self.width.or(base.width),
            max_width: self.max_width.or(base.max_width),
        }
    }

    /// 背景、边框、圆角、阴影、内边距打包成盒子数组（1/100 em 单位）。
    pub fn to_box(&self) -> Option<Vec<i64>> {
        let borders = &self.borders;
        let has_border = borders.iter().any(|side| side.is_some());
        let has_pad = self.padding.iter().any(|value| *value != 0);
        if self.background.is_none()
            && !has_border
            && !self.has_radius
            && self.shadow.is_none()
            && !has_pad
        {
            return None;
        }
        let width = |side: usize| borders[side].as_ref().map_or(0, |b| b.width) as i64;
        let border_color = borders
            .iter()
            .find_map(|side| side.as_ref().map(|b| b.color as i64))
            .unwrap_or(0);
        let shadow = self.shadow.unwrap_or([0, 0, 0, 0]);
        let style = |side: usize| borders[side].as_ref().map_or(1, |b| b.style) as i64;
        Some(vec![
            self.background.map_or(0, |value| value as i64),
            width(0),
            width(1),
            width(2),
            width(3),
            border_color,
            self.radius[0] as i64,
            self.radius[1] as i64,
            self.radius[2] as i64,
            self.radius[3] as i64,
            shadow[0] as i64,
            shadow[1] as i64,
            shadow[2] as i64,
            shadow[3] as i64,
            self.padding[0] as i64,
            self.padding[1] as i64,
            self.padding[2] as i64,
            self.padding[3] as i64,
            // 边框线型：1 实线、2 虚线、3 点线（上、右、下、左）
            style(0),
            style(1),
            style(2),
            style(3),
        ])
    }

    /// 盒子是否会画出背景、边框、圆角或阴影。
    ///
    /// 只有内边距的盒子只负责缩进：书里 `ul { padding-left: 1.5em }` 这种写法
    /// 不能把外层引用框的背景和左边线顶掉，否则引用框会被列表切成几段。
    pub fn box_is_visual(values: &[i64]) -> bool {
        values[0] != 0
            || values[1..5].iter().any(|width| *width != 0)
            || values[6..10].iter().any(|radius| *radius != 0)
            || values[10] != 0
            || values[11] != 0
            || values[12] != 0
    }
}

struct Rule {
    parts: Vec<SelectorPart>,
    child: Vec<bool>,
    spec: i32,
    order: i32,
    props: Props,
}

impl Rule {
    fn matches(&self, tag: &str, id: Option<&str>, classes: &[String], ancestors: &[Key]) -> bool {
        let Some(last) = self.parts.last() else {
            return false;
        };
        if !last.matches(tag, id, classes) {
            return false;
        }
        let mut depth = ancestors.len() as isize - 1;
        for i in (0..self.parts.len().saturating_sub(1)).rev() {
            let part = &self.parts[i];
            if self.child.get(i).copied().unwrap_or(false) {
                if depth < 0 {
                    return false;
                }
                let ancestor = &ancestors[depth as usize];
                if !part.matches(&ancestor.tag, ancestor.id.as_deref(), &ancestor.classes) {
                    return false;
                }
                depth -= 1;
                continue;
            }
            let mut found = false;
            while depth >= 0 {
                let ancestor = &ancestors[depth as usize];
                depth -= 1;
                if part.matches(&ancestor.tag, ancestor.id.as_deref(), &ancestor.classes) {
                    found = true;
                    break;
                }
            }
            if !found {
                return false;
            }
        }
        true
    }
}

pub struct Key {
    pub tag: String,
    pub id: Option<String>,
    pub classes: Vec<String>,
}

pub struct BookStyles {
    rules: Vec<Rule>,
    index: HashMap<String, Vec<usize>>,
}

impl BookStyles {
    pub fn from_json(value: &Value) -> Self {
        let mut rules = vec![];
        if let Some(list) = value.get("rules").and_then(|v| v.as_array()) {
            for item in list {
                if let Some(rule) = parse_rule(item) {
                    rules.push(rule);
                }
            }
        }
        let mut index: HashMap<String, Vec<usize>> = HashMap::new();
        for (i, rule) in rules.iter().enumerate() {
            let Some(last) = rule.parts.last() else {
                continue;
            };
            let mut keyed = false;
            if let Some(id) = &last.id {
                index.entry(format!("i:{id}")).or_default().push(i);
                keyed = true;
            }
            if let Some(tag) = &last.tag {
                index.entry(format!("t:{tag}")).or_default().push(i);
                keyed = true;
            }
            for name in &last.classes {
                index.entry(format!("c:{name}")).or_default().push(i);
                keyed = true;
            }
            if !keyed {
                index.entry("u:*".to_owned()).or_default().push(i);
            }
        }
        Self { rules, index }
    }

    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    /// 计算元素命中的最终声明（不含行内 style）。
    pub fn props_for(
        &self,
        tag: &str,
        id: Option<&str>,
        classes: &[String],
        ancestors: &[Key],
    ) -> Props {
        let mut seen = HashSet::new();
        let mut candidates: Vec<usize> = vec![];
        let mut take = |key: &str, candidates: &mut Vec<usize>| {
            let Some(list) = self.index.get(key) else {
                return;
            };
            for index in list {
                if seen.insert(*index) {
                    candidates.push(*index);
                }
            }
        };
        take(&format!("t:{tag}"), &mut candidates);
        if let Some(id) = id {
            take(&format!("i:{id}"), &mut candidates);
        }
        for name in classes {
            take(&format!("c:{name}"), &mut candidates);
        }
        take("u:*", &mut candidates);
        candidates.sort_by(|a, b| {
            let left = &self.rules[*a];
            let right = &self.rules[*b];
            left.spec
                .cmp(&right.spec)
                .then(left.order.cmp(&right.order))
        });
        let mut props = Props::default();
        for index in candidates {
            let rule = &self.rules[index];
            if !rule.matches(tag, id, classes, ancestors) {
                continue;
            }
            props = rule.props.merge_over(&props);
        }
        props
    }
}

fn parse_rule(value: &Value) -> Option<Rule> {
    let parts: Vec<SelectorPart> = value
        .get("sel")?
        .as_array()?
        .iter()
        .map(parse_part)
        .collect();
    if parts.is_empty() {
        return None;
    }
    let child = value
        .get("child")
        .and_then(|v| v.as_array())
        .map(|list| list.iter().map(|v| v.as_i64().unwrap_or(0) != 0).collect())
        .unwrap_or_default();
    let props = parse_props(value.get("p")?);
    if props.is_empty() {
        return None;
    }
    Some(Rule {
        parts,
        child,
        spec: value.get("spec")?.as_i64()? as i32,
        order: value.get("order")?.as_i64()? as i32,
        props,
    })
}

fn parse_part(value: &Value) -> SelectorPart {
    SelectorPart {
        tag: value.get("t").and_then(|v| v.as_str()).map(str::to_owned),
        id: value.get("i").and_then(|v| v.as_str()).map(str::to_owned),
        classes: value
            .get("c")
            .and_then(|v| v.as_array())
            .map(|list| {
                list.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
    }
}

fn ints(value: Option<&Value>) -> Vec<i64> {
    value
        .and_then(|v| v.as_array())
        .map(|list| list.iter().map(|v| v.as_i64().unwrap_or(0)).collect())
        .unwrap_or_default()
}

fn parse_props(value: &Value) -> Props {
    let mut borders: [Option<Border>; 4] = Default::default();
    if let Some(map) = value.get("bo").and_then(|v| v.as_object()) {
        for (side, raw) in map {
            let values = ints(Some(raw));
            if values.len() < 3 {
                continue;
            }
            let slot = match side.as_str() {
                "t" => 0,
                "r" => 1,
                "b" => 2,
                "l" => 3,
                _ => continue,
            };
            borders[slot] = Some(Border {
                width: values[0] as i32,
                style: values[1] as i32,
                color: values[2] as u32,
            });
        }
    }
    let radius = ints(value.get("rad"));
    let padding = ints(value.get("pad"));
    let shadow = ints(value.get("sh"));
    let text_shadow = ints(value.get("tsh"));
    Props {
        align: value.get("a").and_then(|v| v.as_i64()).map(|v| v as i32),
        indent: value.get("ind").and_then(|v| v.as_i64()).map(|v| v as i32),
        weight: value.get("w").and_then(|v| v.as_i64()).map(|v| v as i32),
        italic: value.get("i").and_then(|v| v.as_i64()).map(|v| v as i32),
        size: value.get("fs").and_then(|v| v.as_f64()),
        color: value.get("c").and_then(|v| v.as_i64()).map(|v| v as u32),
        background: value.get("bg").and_then(|v| v.as_i64()).map(|v| v as u32),
        borders,
        radius: if radius.len() == 4 {
            [radius[0], radius[1], radius[2], radius[3]]
        } else {
            [0; 4]
        },
        has_radius: radius.len() == 4,
        shadow: if shadow.len() == 4 {
            Some([shadow[0], shadow[1], shadow[2], shadow[3]])
        } else {
            None
        },
        padding: if padding.len() == 4 {
            [padding[0], padding[1], padding[2], padding[3]]
        } else {
            [0; 4]
        },
        has_padding: padding.len() == 4,
        list_style: value.get("ls").and_then(|v| v.as_i64()).map(|v| v as i32),
        pre: value.get("pre").and_then(|v| v.as_bool()).unwrap_or(false),
        margins: margins(value.get("mg")),
        text_shadow: if text_shadow.len() == 4 {
            Some([
                text_shadow[0],
                text_shadow[1],
                text_shadow[2],
                text_shadow[3],
            ])
        } else {
            None
        },
        decoration: value.get("dec").and_then(|v| v.as_i64()).map(|v| v as i32),
        letter_spacing: value.get("lsp").and_then(|v| v.as_i64()),
        word_spacing: value.get("wsp").and_then(|v| v.as_i64()),
        width: size(value.get("wid")),
        max_width: size(value.get("mw")),
    }
}

/// `[数值, 单位]` 形式的宽度声明。
fn size(value: Option<&Value>) -> Option<[i64; 2]> {
    let list = value?.as_array()?;
    if list.len() != 2 {
        return None;
    }
    Some([list[0].as_i64()?, list[1].as_i64()?])
}

/// 解析一个颜色写法（与 Dart 侧的归一化规则一致）。
pub fn parse_color(value: &str) -> Option<u32> {
    let text = value.trim().to_lowercase();
    if text.is_empty() || text == "transparent" || text == "inherit" || text == "initial" {
        return None;
    }
    if let Some(hex) = text.strip_prefix('#') {
        let parse = |s: &str| u32::from_str_radix(s, 16).ok();
        return match hex.len() {
            3 => {
                let r = parse(&hex[0..1].repeat(2))?;
                let g = parse(&hex[1..2].repeat(2))?;
                let b = parse(&hex[2..3].repeat(2))?;
                Some(0xFF00_0000 | (r << 16) | (g << 8) | b)
            }
            6 => Some(0xFF00_0000 | parse(hex)?),
            8 => parse(hex),
            _ => None,
        };
    }
    if text.starts_with("rgb") {
        let inner = text
            .strip_prefix("rgba(")
            .or_else(|| text.strip_prefix("rgb("))?
            .strip_suffix(')')?;
        let parts: Vec<&str> = inner
            .split(|c| c == ',' || c == ' ' || c == '/')
            .filter(|part| !part.is_empty())
            .collect();
        if parts.len() < 3 {
            return None;
        }
        let channel = |raw: &str| -> Option<u32> {
            let value: f64 = raw.trim().parse().ok()?;
            Some(value.round().clamp(0.0, 255.0) as u32)
        };
        let r = channel(parts[0])?;
        let g = channel(parts[1])?;
        let b = channel(parts[2])?;
        let mut alpha = 255u32;
        if let Some(raw) = parts.get(3) {
            let raw = raw.trim();
            let value: f64 = raw.trim_end_matches('%').parse().ok()?;
            alpha = if raw.ends_with('%') {
                (value / 100.0 * 255.0).round().clamp(0.0, 255.0) as u32
            } else {
                (value * 255.0).round().clamp(0.0, 255.0) as u32
            };
        }
        return Some((alpha << 24) | (r << 16) | (g << 8) | b);
    }
    let named = match text.as_str() {
        "black" => 0xFF00_0000,
        "white" => 0xFFFF_FFFF,
        "red" => 0xFFFF_0000,
        "green" => 0xFF00_8000,
        "blue" => 0xFF00_00FF,
        "gray" | "grey" => 0xFF80_8080,
        "silver" => 0xFFC0_C0C0,
        "yellow" => 0xFFFF_FF00,
        "orange" => 0xFFFF_A500,
        "purple" => 0xFF80_0080,
        "pink" => 0xFFFF_C0CB,
        "brown" => 0xFFA5_2A2A,
        "navy" => 0xFF00_0080,
        "teal" => 0xFF00_8080,
        "olive" => 0xFF80_8000,
        "maroon" => 0xFF80_0000,
        "lime" => 0xFF00_FF00,
        "aqua" | "cyan" => 0xFF00_FFFF,
        "magenta" | "fuchsia" => 0xFFFF_00FF,
        "darkgray" | "darkgrey" => 0xFFA9_A9A9,
        "lightgray" | "lightgrey" => 0xFFD3_D3D3,
        "whitesmoke" => 0xFFF5_F5F5,
        "gainsboro" => 0xFFDC_DCDC,
        _ => return None,
    };
    Some(named)
}

/// 解析相对字号（em／rem／%／关键字）；px、pt 一律不采用。
pub fn parse_relative_size(value: &str) -> Option<f64> {
    let text = value.trim().to_lowercase();
    if text.is_empty() {
        return None;
    }
    let keyword = match text.as_str() {
        "xx-small" => Some(0.6),
        "x-small" => Some(0.75),
        "small" => Some(0.85),
        "medium" => Some(1.0),
        "large" => Some(1.2),
        "x-large" => Some(1.4),
        "xx-large" => Some(1.6),
        "smaller" => Some(0.85),
        "larger" => Some(1.2),
        _ => None,
    };
    if let Some(value) = keyword {
        return Some(value);
    }
    let (number, unit) = if let Some(value) = text.strip_suffix('%') {
        (value, "%")
    } else if let Some(value) = text.strip_suffix("rem") {
        (value, "em")
    } else if let Some(value) = text.strip_suffix("em") {
        (value, "em")
    } else {
        return None;
    };
    let number: f64 = number.trim().parse().ok()?;
    if number <= 0.0 {
        return None;
    }
    let factor = if unit == "%" { number / 100.0 } else { number };
    Some(factor.clamp(0.5, 2.2))
}

/// 行内 `text-decoration`：0 无、1 下划线、2 删除线、3 两者都有。
/// 与 Dart 侧 `BookStyles.parseDecoration` 口径一致。
pub fn parse_decoration(value: &str) -> Option<u8> {
    let mut bits = 0u8;
    for token in value.trim().to_lowercase().split_whitespace() {
        if token == "none" {
            return Some(0);
        }
        if token.starts_with("underline") {
            bits |= 1;
        }
        if token.starts_with("line-through") {
            bits |= 2;
        }
    }
    if bits == 0 { None } else { Some(bits) }
}

/// 行内 `width`／`max-width`：只认 `%`、`em`、`rem`、`px`。
/// 返回 `[数值(单位的 1/100), 单位]`，单位 1 百分比、2 em、3 px。
pub fn parse_size(value: &str) -> Option<[i64; 2]> {
    let text = value.trim().to_lowercase();
    let (number, unit) = if let Some(value) = text.strip_suffix('%') {
        (value, 1i64)
    } else if let Some(value) = text.strip_suffix("rem") {
        (value, 2)
    } else if let Some(value) = text.strip_suffix("em") {
        (value, 2)
    } else if let Some(value) = text.strip_suffix("px") {
        (value, 3)
    } else {
        return None;
    };
    let number: f64 = number.trim().parse().ok()?;
    if number < 0.0 {
        return None;
    }
    Some([(number * 100.0).round() as i64, unit])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn book(rules: Value) -> BookStyles {
        BookStyles::from_json(&json!({"v": 1, "rules": rules}))
    }

    fn part(tag: Option<&str>, id: Option<&str>, classes: &[&str]) -> Value {
        let mut value = json!({});
        if let Some(tag) = tag {
            value["t"] = json!(tag);
        }
        if let Some(id) = id {
            value["i"] = json!(id);
        }
        if !classes.is_empty() {
            value["c"] = json!(classes);
        }
        value
    }

    #[test]
    fn child_combinator_matches_ancestor() {
        let styles = book(json!([
            {"sel": [part(Some("ol"), None, &[])], "spec": 1, "order": 0,
             "p": {"pad": [0, 0, 0, 150]}},
            {"sel": [part(Some("nav"), Some("toc"), &[]), part(Some("ol"), None, &["toc"])],
             "child": [1], "spec": 10301, "order": 1, "p": {"pad": [0, 0, 0, 0], "pre": false}}
        ]));
        let ancestors = vec![Key {
            tag: "nav".to_owned(),
            id: Some("toc".to_owned()),
            classes: vec![],
        }];
        let props = styles.props_for("ol", None, &["toc".to_owned()], &ancestors);
        // 高优先级规则把 padding 覆盖成 0：没有盒子
        assert!(props.to_box().is_none(), "padding 应被覆盖为 0");
    }

    #[test]
    fn descendant_and_class_matching() {
        let styles = book(json!([
            {"sel": [part(None, None, &["box"]), part(Some("p"), None, &[])],
             "spec": 101, "order": 0, "p": {"c": 4294901760u32}},
        ]));
        let ancestors = vec![Key {
            tag: "div".to_owned(),
            id: None,
            classes: vec!["box".to_owned()],
        }];
        let props = styles.props_for("p", None, &[], &ancestors);
        assert_eq!(props.color, Some(4294901760u32));
    }
}

/// `mg`：四个整数，`[上, 右, 下, 左]`，单位是百分之一 em（`1em` 记为 100）。
fn margins(value: Option<&Value>) -> Option<Vec<i64>> {
    let list = value?.as_array()?;
    if list.len() != 4 {
        return None;
    }
    Some(list.iter().map(|v| v.as_i64().unwrap_or(0)).collect())
}
#[cfg(test)]
mod margins_probe {
    use super::*;
    use serde_json::json;

    #[test]
    fn margin_props_round_trip() {
        let props = parse_props(&json!({"mg": [100, 0, 100, 0]}));
        assert_eq!(props.margins, Some(vec![100, 0, 100, 0]));
        assert!(!props.is_empty());
        let merged = props.merge_over(&Props::default());
        assert_eq!(merged.margins, Some(vec![100, 0, 100, 0]));
    }
}
/// 行内样式里的单个长度（em／px），换算成百分之一 em；`auto`、百分比与非法值返回 None。
pub fn parse_margin_length(value: &str) -> Option<i64> {
    let text = value.trim().to_lowercase();
    if text.is_empty() || text == "auto" {
        return None;
    }
    if text == "0" {
        return Some(0);
    }
    let (number, unit) = if let Some(rest) = text.strip_suffix("px") {
        (rest.trim().parse::<f64>().ok()?, "px")
    } else if let Some(rest) = text.strip_suffix("em") {
        (rest.trim().parse::<f64>().ok()?, "em")
    } else {
        return None;
    };
    let em = if unit == "px" { number / 16.0 } else { number };
    Some((em * 100.0).round() as i64)
}

/// 行内 `margin` 简写（1～4 个值）展开成四边，单位百分之一 em。
pub fn parse_margin_shorthand(value: &str) -> Option<[i64; 4]> {
    let mut values = Vec::new();
    for part in value.split_whitespace() {
        values.push(parse_margin_length(part).unwrap_or(0));
    }
    match values.len() {
        1 => Some([values[0]; 4]),
        2 => Some([values[0], values[1], values[0], values[1]]),
        3 => Some([values[0], values[1], values[2], values[1]]),
        4 => Some([values[0], values[1], values[2], values[3]]),
        _ => None,
    }
}
