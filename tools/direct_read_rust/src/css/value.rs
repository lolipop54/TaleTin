// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 统一 CSS 值解析：长度保留单位，颜色保留原始语义，非法值返回 None。
//!
//! 这一层只把「书里写的值」变成类型化值，不乘成最终像素；`em/%/auto` 的最终
//! 解析留给排版上下文。旧转换器需要的「百分之一 em」整数由 `to_legacy` 提供，
//! 只作为迁移期结构字段，新的样式表仍使用带单位值。

use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Length {
    Em(f64),
    Rem(f64),
    Percent(f64),
    Px(f64),
    Pt(f64),
    Auto,
}

impl Length {
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Length::Em(v) => serde_json::json!({"u": "em", "v": v}),
            Length::Rem(v) => serde_json::json!({"u": "rem", "v": v}),
            Length::Percent(v) => serde_json::json!({"u": "%", "v": v}),
            Length::Px(v) => serde_json::json!({"u": "px", "v": v}),
            Length::Pt(v) => serde_json::json!({"u": "pt", "v": v}),
            Length::Auto => serde_json::json!("auto"),
        }
    }

    /// 旧显示字段用「百分之一 em」；px 按 16px=1em、pt 按 12pt=1em（与旧解析器一致）。
    /// 百分比和 auto 在旧结构里没有准确表示，返回 None，让调用方跳过而不是猜一个值。
    pub fn to_hundredths_em(&self) -> Option<i64> {
        Some(match self {
            Length::Em(v) => (v * 100.0).round() as i64,
            Length::Rem(v) => (v * 100.0).round() as i64,
            Length::Px(v) => (v / 16.0 * 100.0).round() as i64,
            Length::Pt(v) => (v * 4.0 / 3.0 / 16.0 * 100.0).round() as i64,
            Length::Auto => return None,
            Length::Percent(_) => return None,
        })
    }

    pub fn is_zero(&self) -> bool {
        matches!(
            self,
            Length::Em(v) | Length::Rem(v) | Length::Percent(v) | Length::Px(v) | Length::Pt(v)
                if *v == 0.0
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FontSize {
    pub unit: FontSizeUnit,
    pub value: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FontSizeUnit {
    Em,
    Rem,
    Px,
}

impl FontSize {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "u": match self.unit {
                FontSizeUnit::Em => "em",
                FontSizeUnit::Rem => "rem",
                FontSizeUnit::Px => "px",
            },
            "v": self.value,
        })
    }

    /// 相对父级算成「相对正文的倍数」；绝对 px 不参与用户字号缩放。
    pub fn resolve_factor(&self, parent_factor: f64) -> Option<f64> {
        match self.unit {
            FontSizeUnit::Em => Some(parent_factor * self.value),
            FontSizeUnit::Rem => Some(self.value),
            FontSizeUnit::Px => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum LineHeight {
    Normal,
    Factor(f64),
    Percent(f64),
    Length(Length),
}

impl LineHeight {
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            LineHeight::Normal => serde_json::json!("normal"),
            LineHeight::Factor(v) => serde_json::json!(v),
            LineHeight::Percent(v) => serde_json::json!({"u": "%", "v": v}),
            LineHeight::Length(v) => serde_json::json!({"u": "len", "v": v.to_json()}),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Color {
    Argb(u32),
    Current,
}

impl Color {
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Color::Argb(value) => serde_json::json!(value),
            Color::Current => serde_json::json!("currentColor"),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Edges {
    pub top: Option<Length>,
    pub right: Option<Length>,
    pub bottom: Option<Length>,
    pub left: Option<Length>,
}

impl Edges {
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        if let Some(value) = &self.top {
            map.insert("t".to_owned(), value.to_json());
        }
        if let Some(value) = &self.right {
            map.insert("r".to_owned(), value.to_json());
        }
        if let Some(value) = &self.bottom {
            map.insert("b".to_owned(), value.to_json());
        }
        if let Some(value) = &self.left {
            map.insert("l".to_owned(), value.to_json());
        }
        serde_json::Value::Object(map)
    }

    pub fn all(value: Length) -> Self {
        Self {
            top: Some(value.clone()),
            right: Some(value.clone()),
            bottom: Some(value.clone()),
            left: Some(value),
        }
    }

    pub fn from_four(values: &[Length]) -> Option<Self> {
        Some(match values {
            [all] => Self::all(all.clone()),
            [vertical, horizontal] => Self {
                top: Some(vertical.clone()),
                right: Some(horizontal.clone()),
                bottom: Some(vertical.clone()),
                left: Some(horizontal.clone()),
            },
            [top, horizontal, bottom] => Self {
                top: Some(top.clone()),
                right: Some(horizontal.clone()),
                bottom: Some(bottom.clone()),
                left: Some(horizontal.clone()),
            },
            [top, right, bottom, left] => Self {
                top: Some(top.clone()),
                right: Some(right.clone()),
                bottom: Some(bottom.clone()),
                left: Some(left.clone()),
            },
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct BorderSide {
    pub width: Option<Length>,
    pub style: Option<String>,
    pub color: Option<Color>,
}

impl BorderSide {
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        if let Some(width) = &self.width {
            map.insert("w".to_owned(), width.to_json());
        }
        if let Some(style) = &self.style {
            map.insert("s".to_owned(), serde_json::json!(style));
        }
        if let Some(color) = &self.color {
            map.insert("c".to_owned(), color.to_json());
        }
        serde_json::Value::Object(map)
    }

    pub fn is_visible(&self) -> bool {
        let Some(style) = &self.style else {
            return false;
        };
        if style == "none" || style == "hidden" {
            return false;
        }
        self.width.as_ref().is_none_or(|width| !width.is_zero())
    }

    pub fn width_hundredths(&self) -> i64 {
        self.width
            .as_ref()
            .and_then(Length::to_hundredths_em)
            .unwrap_or(0)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Shadow {
    pub x: Length,
    pub y: Length,
    pub blur: Option<Length>,
    pub spread: Option<Length>,
    pub color: Option<Color>,
    pub inset: bool,
}

impl Shadow {
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        map.insert("x".to_owned(), self.x.to_json());
        map.insert("y".to_owned(), self.y.to_json());
        if let Some(blur) = &self.blur {
            map.insert("b".to_owned(), blur.to_json());
        }
        if let Some(spread) = &self.spread {
            map.insert("s".to_owned(), spread.to_json());
        }
        if let Some(color) = &self.color {
            map.insert("c".to_owned(), color.to_json());
        }
        if self.inset {
            map.insert("i".to_owned(), serde_json::json!(true));
        }
        serde_json::Value::Object(map)
    }

    pub fn legacy(&self) -> Option<[i64; 4]> {
        Some([
            self.x.to_hundredths_em()?,
            self.y.to_hundredths_em()?,
            self.blur
                .as_ref()
                .and_then(Length::to_hundredths_em)
                .unwrap_or(0),
            match &self.color {
                Some(Color::Argb(value)) => *value as i64,
                _ => 0,
            },
        ])
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Background {
    pub color: Option<Color>,
    pub image: Option<String>,
    pub repeat: Option<String>,
    pub position: Option<String>,
    pub size: Option<String>,
    pub raw: Option<String>,
}

impl Background {
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        if let Some(color) = &self.color {
            map.insert("c".to_owned(), color.to_json());
        }
        if let Some(image) = &self.image {
            map.insert("u".to_owned(), serde_json::json!(image));
        }
        if let Some(repeat) = &self.repeat {
            map.insert("r".to_owned(), serde_json::json!(repeat));
        }
        if let Some(position) = &self.position {
            map.insert("p".to_owned(), serde_json::json!(position));
        }
        if let Some(size) = &self.size {
            map.insert("s".to_owned(), serde_json::json!(size));
        }
        if let Some(raw) = &self.raw {
            map.insert("raw".to_owned(), serde_json::json!(raw));
        }
        serde_json::Value::Object(map)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Decoration {
    pub lines: Vec<&'static str>,
    pub color: Option<Color>,
    pub style: Option<String>,
    pub thickness: Option<Length>,
}

impl Decoration {
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        if !self.lines.is_empty() {
            let mut lines = self.lines.clone();
            lines.sort_unstable();
            map.insert("l".to_owned(), serde_json::json!(lines));
        }
        if let Some(color) = &self.color {
            map.insert("c".to_owned(), color.to_json());
        }
        if let Some(style) = &self.style {
            map.insert("s".to_owned(), serde_json::json!(style));
        }
        if let Some(thickness) = &self.thickness {
            map.insert("t".to_owned(), thickness.to_json());
        }
        serde_json::Value::Object(map)
    }

    pub fn bits(&self) -> u8 {
        let mut bits = 0;
        if self.lines.contains(&"underline") {
            bits |= 1;
        }
        if self.lines.contains(&"lineThrough") {
            bits |= 2;
        }
        bits
    }
}

#[path = "colors.rs"]
mod colors;
pub use colors::parse_color;

pub fn parse_length(value: &str) -> Option<Length> {
    let value = value.trim();
    if value.eq_ignore_ascii_case("auto") {
        return Some(Length::Auto);
    }
    if value == "0" {
        return Some(Length::Px(0.0));
    }
    let (number, unit) = split_number_unit(value)?;
    Some(match unit {
        "" => return None,
        "em" => Length::Em(number),
        "rem" => Length::Rem(number),
        "%" => Length::Percent(number / 100.0),
        "px" => Length::Px(number),
        "pt" => Length::Pt(number),
        _ => return None,
    })
}

pub fn parse_font_size(value: &str) -> Option<FontSize> {
    let value = value.trim().to_ascii_lowercase();
    let keyword = match value.as_str() {
        "xx-small" => Some(0.6),
        "x-small" => Some(0.75),
        "small" => Some(0.85),
        "medium" => Some(1.0),
        "large" => Some(1.2),
        "x-large" => Some(1.5),
        "xx-large" => Some(2.0),
        "smaller" => Some(0.85),
        "larger" => Some(1.2),
        _ => None,
    };
    if let Some(value) = keyword {
        return Some(FontSize {
            unit: FontSizeUnit::Em,
            value,
        });
    }
    let (number, unit) = split_number_unit(&value)?;
    Some(match unit {
        "em" => FontSize {
            unit: FontSizeUnit::Em,
            value: number,
        },
        "rem" => FontSize {
            unit: FontSizeUnit::Rem,
            value: number,
        },
        "%" => FontSize {
            unit: FontSizeUnit::Em,
            value: number / 100.0,
        },
        "px" => FontSize {
            unit: FontSizeUnit::Px,
            value: number,
        },
        "pt" => FontSize {
            unit: FontSizeUnit::Px,
            value: number * 4.0 / 3.0,
        },
        _ => return None,
    })
}

pub fn parse_line_height(value: &str) -> Option<LineHeight> {
    let value = value.trim().to_ascii_lowercase();
    if value == "normal" {
        return Some(LineHeight::Normal);
    }
    if let Ok(factor) = value.parse::<f64>() {
        return Some(LineHeight::Factor(factor));
    }
    if let Some((number, unit)) = split_number_unit(&value) {
        if unit == "%" {
            return Some(LineHeight::Percent(number / 100.0));
        }
    }
    parse_length(&value).map(LineHeight::Length)
}

pub fn parse_font_weight(value: &str) -> Option<(u16, Option<&'static str>)> {
    match value.trim().to_ascii_lowercase().as_str() {
        "normal" => Some((400, None)),
        "bold" => Some((700, None)),
        "bolder" => Some((400, Some("bolder"))),
        "lighter" => Some((400, Some("lighter"))),
        numeric => numeric
            .parse::<u16>()
            .ok()
            .filter(|value| (100..=900).contains(value))
            .map(|value| (value, None)),
    }
}

pub fn parse_spacing(value: &str) -> Option<Option<Length>> {
    let text = value.trim();
    if text.eq_ignore_ascii_case("normal") {
        return Some(None);
    }
    parse_length(text).map(Some)
}

pub fn split_top_level(value: &str, separator: char) -> Vec<String> {
    let mut result = Vec::new();
    let mut depth = 0i32;
    let mut quote = None;
    let mut start = 0usize;
    for (index, ch) in value.char_indices() {
        if let Some(active) = quote {
            if ch == active {
                quote = None;
            }
            continue;
        }
        match ch {
            '"' | '\'' => quote = Some(ch),
            '(' => depth += 1,
            ')' => depth -= 1,
            _ if ch == separator && depth == 0 => {
                result.push(value[start..index].trim().to_owned());
                start = index + ch.len_utf8();
            }
            _ => {}
        }
    }
    result.push(value[start..].trim().to_owned());
    result
}

pub fn split_whitespace_top_level(value: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut depth = 0i32;
    let mut quote = None;
    let mut current = String::new();
    for ch in value.chars() {
        if let Some(active) = quote {
            current.push(ch);
            if ch == active {
                quote = None;
            }
            continue;
        }
        match ch {
            '"' | '\'' => {
                quote = Some(ch);
                current.push(ch);
            }
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth -= 1;
                current.push(ch);
            }
            _ if ch.is_whitespace() && depth == 0 => {
                if !current.is_empty() {
                    result.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(ch),
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

pub fn parse_shadow_list(value: &str, box_shadow: bool) -> Option<Vec<Shadow>> {
    if value.trim().eq_ignore_ascii_case("none") {
        return Some(vec![]);
    }
    let mut shadows = Vec::new();
    for part in split_top_level(value, ',') {
        let tokens = split_whitespace_top_level(&part);
        if tokens.is_empty() {
            return None;
        }
        let mut lengths = Vec::new();
        let mut color = None;
        let mut inset = false;
        for token in tokens {
            if token.eq_ignore_ascii_case("inset") {
                inset = true;
            } else if let Some(value) = parse_color(&token) {
                color = Some(value);
            } else if let Some(value) = parse_length(&token) {
                lengths.push(value);
            }
        }
        if lengths.len() < 2 {
            return None;
        }
        shadows.push(Shadow {
            x: lengths[0].clone(),
            y: lengths[1].clone(),
            blur: lengths.get(2).cloned(),
            spread: if box_shadow {
                lengths.get(3).cloned()
            } else {
                None
            },
            color,
            inset,
        });
    }
    Some(shadows)
}

pub fn parse_border_side(value: &str) -> BorderSide {
    let mut side = BorderSide {
        width: None,
        style: None,
        color: None,
    };
    for token in split_whitespace_top_level(value) {
        let lower = token.to_ascii_lowercase();
        if matches!(
            lower.as_str(),
            "none"
                | "hidden"
                | "solid"
                | "dashed"
                | "dotted"
                | "double"
                | "groove"
                | "ridge"
                | "inset"
                | "outset"
        ) {
            side.style = Some(lower);
        } else if let Some(color) = parse_color(&token) {
            side.color = Some(color);
        } else if let Some(width) = parse_border_width(&token) {
            side.width = Some(width);
        }
    }
    side
}

pub fn parse_border_width(value: &str) -> Option<Length> {
    match value.trim().to_ascii_lowercase().as_str() {
        "thin" => Some(Length::Px(1.0)),
        "medium" => Some(Length::Px(3.0)),
        "thick" => Some(Length::Px(5.0)),
        "0" => Some(Length::Px(0.0)),
        _ => parse_length(value),
    }
}

pub fn parse_background(value: &str) -> Background {
    let mut background = Background {
        color: None,
        image: None,
        repeat: None,
        position: None,
        size: None,
        raw: Some(value.trim().to_owned()),
    };
    let sides = split_top_level(value, '/');
    let mut positions = Vec::new();
    let mut repeats = Vec::new();
    let mut sizes = Vec::new();
    for (part, side) in sides.iter().enumerate() {
        for token in split_whitespace_top_level(side) {
            let lower = token.to_ascii_lowercase();
            if lower.starts_with("url(") {
                background.image = parse_url(&token);
            } else if matches!(
                lower.as_str(),
                "repeat" | "repeat-x" | "repeat-y" | "no-repeat" | "space" | "round"
            ) {
                repeats.push(lower);
            } else if let Some(color) = parse_color(&token) {
                background.color = Some(color);
            } else if part > 0
                && (matches!(lower.as_str(), "cover" | "contain" | "auto")
                    || parse_length(&token).is_some())
            {
                sizes.push(lower);
            } else if part == 0
                && (matches!(
                    lower.as_str(),
                    "left" | "right" | "top" | "bottom" | "center"
                ) || parse_length(&token).is_some())
            {
                positions.push(lower);
            }
        }
    }
    if !positions.is_empty() {
        background.position = Some(positions.join(" "));
    }
    if !repeats.is_empty() {
        background.repeat = Some(repeats.join(" "));
    }
    if !sizes.is_empty() {
        background.size = Some(sizes.join(" "));
    }
    background
}

pub fn parse_url(value: &str) -> Option<String> {
    let mut parser = cssparser::Parser::new(value);
    let url = parser.expect_url().ok()?.to_string();
    if !parser.is_exhausted() || url.is_empty() {
        None
    } else {
        Some(url)
    }
}

pub fn parse_decoration(value: &str) -> Decoration {
    let mut decoration = Decoration {
        lines: vec![],
        color: None,
        style: None,
        thickness: None,
    };
    for token in split_whitespace_top_level(value) {
        let lower = token.to_ascii_lowercase();
        match lower.as_str() {
            "none" => decoration.lines.clear(),
            "underline" => decoration.lines.push("underline"),
            "overline" => decoration.lines.push("overline"),
            "line-through" => decoration.lines.push("lineThrough"),
            "blink" => {}
            "solid" | "double" | "dotted" | "dashed" | "wavy" => decoration.style = Some(lower),
            _ => {
                if let Some(color) = parse_color(&token) {
                    decoration.color = Some(color);
                } else if let Some(thickness) = parse_length(&token) {
                    decoration.thickness = Some(thickness);
                }
            }
        }
    }
    decoration
}

pub fn parse_list_style(value: &str) -> Option<(Option<&'static str>, Option<&'static str>)> {
    let mut kind = None;
    let mut position = None;
    for token in split_whitespace_top_level(value) {
        let lower = token.to_ascii_lowercase();
        if let Some(value) = list_style_type(&lower) {
            kind = Some(value);
        } else if lower == "inside" || lower == "outside" {
            position = Some(if lower == "inside" {
                "inside"
            } else {
                "outside"
            });
        } else if lower.starts_with("url(") {
            // list-style-image 目前只记录，不改变标记。
        }
    }
    Some((kind, position))
}

pub fn list_style_type(value: &str) -> Option<&'static str> {
    Some(match value {
        "none" => "none",
        "disc" => "disc",
        "circle" => "circle",
        "square" => "square",
        "decimal" => "decimal",
        "decimal-leading-zero" => "decimalLeadingZero",
        "lower-alpha" | "lower-latin" => "lowerAlpha",
        "upper-alpha" | "upper-latin" => "upperAlpha",
        "lower-greek" => "lowerGreek",
        "lower-roman" => "lowerRoman",
        "upper-roman" => "upperRoman",
        _ => return None,
    })
}

pub fn parse_keyword(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn split_number_unit(value: &str) -> Option<(f64, &str)> {
    let value = value.trim();
    let number_end = value
        .char_indices()
        .find(|(_, ch)| !(*ch == '+' || *ch == '-' || *ch == '.' || ch.is_ascii_digit()))
        .map(|(index, _)| index)
        .unwrap_or(value.len());
    if number_end == 0 {
        return None;
    }
    let number = value[..number_end].parse::<f64>().ok()?;
    Some((number, value[number_end..].trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths_keep_units() {
        assert_eq!(parse_length("1.5em"), Some(Length::Em(1.5)));
        assert_eq!(parse_length("50%"), Some(Length::Percent(0.5)));
        assert_eq!(parse_length("12px"), Some(Length::Px(12.0)));
        assert_eq!(parse_length("auto"), Some(Length::Auto));
        assert_eq!(parse_length("12"), None);
    }

    #[test]
    fn colors_cover_hex_rgb_and_names() {
        assert_eq!(parse_color("#abc"), Some(Color::Argb(0xFFAABBCC)));
        assert_eq!(parse_color("rgb(1, 2, 3)"), Some(Color::Argb(0xFF010203)));
        assert_eq!(parse_color("red"), Some(Color::Argb(0xFFFF0000)));
        assert_eq!(parse_color("currentColor"), Some(Color::Current));
    }

    #[test]
    fn shadows_keep_all_layers() {
        let shadows = parse_shadow_list("1px 2px 3px #000, 0 0 1em red", true).unwrap();
        assert_eq!(shadows.len(), 2);
        assert_eq!(shadows[0].blur, Some(Length::Px(3.0)));
        assert_eq!(shadows[1].color, Some(Color::Argb(0xFFFF0000)));
    }

    #[test]
    fn border_side_parses_three_parts() {
        let side = parse_border_side("1px solid #ccc");
        assert_eq!(side.width, Some(Length::Px(1.0)));
        assert_eq!(side.style.as_deref(), Some("solid"));
        assert_eq!(side.color, Some(Color::Argb(0xFFCCCCCC)));
    }
}
