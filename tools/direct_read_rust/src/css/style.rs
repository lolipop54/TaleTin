// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 一个元素的计算样式，以及迁移期给旧转换器的 `Props` 形状。
//!
//! `Computed` 只保存作者侧（标签默认 + 作者样式 + 行内样式）的结果，单位仍是
//! em／%／px；`Props` 是旧 `html.rs` 使用的整数形状，由 `Computed` 换算，保证
//! 正文、块号和当前页面几何在接入新 CSS 时不变。

use std::collections::HashMap;

use serde_json::{Value, json};

use super::value::{
    Background, BorderSide, Color, Decoration, Edges, FontSize, FontSizeUnit, Length, LineHeight,
    Shadow,
};

#[derive(Clone, Debug, Default)]
pub struct Computed {
    pub font_size: Option<FontSize>,
    /// 相对正文的累计字号倍数；绝对 px 不参与用户字号缩放。
    pub font_size_factor: Option<f64>,
    /// 本元素是否有胜出的字号声明；继承到的 1em 不能冒充标题自身写了字号。
    pub font_size_declared: bool,
    /// `bolder/lighter` 先保留，层叠时再相对父级算。
    pub font_weight: Option<u16>,
    pub font_weight_relative: Option<&'static str>,
    pub font_style: Option<&'static str>,
    pub font_family: Option<Vec<String>>,
    pub color: Option<Color>,
    pub line_height: Option<LineHeight>,
    pub decoration: Option<Decoration>,
    pub text_shadow: Option<Vec<Shadow>>,
    pub letter_spacing: Option<Option<Length>>,
    pub word_spacing: Option<Option<Length>>,
    pub text_transform: Option<&'static str>,
    pub vertical_align: Option<String>,
    pub white_space: Option<&'static str>,
    pub hyphens: Option<String>,

    pub background: Option<Background>,
    pub border: [BorderSide; 4],
    pub radii: Option<[Length; 4]>,
    pub box_shadow: Option<Vec<Shadow>>,
    pub padding: Option<Edges>,
    pub overflow: Option<String>,

    pub display: Option<&'static str>,
    pub margin: Option<Edges>,
    pub inset: Option<Edges>,
    pub text_align: Option<&'static str>,
    pub text_align_last: Option<&'static str>,
    pub text_indent: Option<Length>,
    pub float: Option<&'static str>,
    pub clear: Option<&'static str>,
    pub position: Option<&'static str>,
    pub break_before: Option<String>,
    pub break_after: Option<String>,
    pub break_inside: Option<String>,
    pub list_style_type: Option<&'static str>,
    pub list_style_position: Option<&'static str>,

    pub width: Option<Length>,
    pub height: Option<Length>,
    pub min_width: Option<Length>,
    pub min_height: Option<Length>,
    pub max_width: Option<Length>,
    pub max_height: Option<Length>,
    pub box_sizing: Option<&'static str>,
    pub object_fit: Option<String>,

    pub border_collapse: Option<String>,
    pub border_spacing: Option<Length>,
    pub table_layout: Option<String>,
    pub caption_side: Option<String>,
    pub empty_cells: Option<String>,

    /// 书里出现但当前布局不能消费的属性；不写进正式缓存，只做诊断。
    pub extras: HashMap<String, String>,
}

impl Computed {
    pub fn is_empty(&self) -> bool {
        self.to_json().as_object().is_some_and(|map| map.is_empty())
    }

    /// 生成与 Dart `computed_style_json.dart` 完全一致的短键结构。
    pub fn to_json(&self) -> Value {
        let mut root = serde_json::Map::new();
        let text = self.text_json();
        if !text.is_empty() {
            root.insert("t".to_owned(), Value::Object(text));
        }
        let box_style = self.box_json();
        if !box_style.is_empty() {
            root.insert("b".to_owned(), Value::Object(box_style));
        }
        let block = self.block_json();
        if !block.is_empty() {
            root.insert("k".to_owned(), Value::Object(block));
        }
        let size = self.size_json();
        if !size.is_empty() {
            root.insert("s".to_owned(), Value::Object(size));
        }
        let table = self.table_json();
        if !table.is_empty() {
            root.insert("tb".to_owned(), Value::Object(table));
        }
        Value::Object(root)
    }

    fn text_json(&self) -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        if let Some(value) = &self.font_size {
            let json = if let Some(factor) = self.font_size_factor {
                // 样式表里的字号是「相对正文的累计倍数」，与旧 run.sizeScale 口径一致。
                FontSize {
                    unit: FontSizeUnit::Em,
                    value: factor,
                }
                .to_json()
            } else {
                value.to_json()
            };
            out.insert("fs".to_owned(), json);
        }
        if let Some(value) = self.font_weight {
            if let Some(mode) = self.font_weight_relative {
                out.insert("fw".to_owned(), json!({"v": value, "m": mode}));
            } else {
                out.insert("fw".to_owned(), json!(value));
            }
        }
        if let Some(value) = self.font_style {
            out.insert("fy".to_owned(), json!(value));
        }
        if let Some(value) = &self.font_family {
            out.insert("ff".to_owned(), json!(value));
        }
        if let Some(value) = &self.color {
            out.insert("c".to_owned(), value.to_json());
        }
        if let Some(value) = &self.line_height {
            out.insert("lh".to_owned(), value.to_json());
        }
        if let Some(value) = &self.decoration {
            out.insert("d".to_owned(), value.to_json());
        }
        if let Some(value) = &self.text_shadow {
            out.insert(
                "sh".to_owned(),
                Value::Array(value.iter().map(Shadow::to_json).collect()),
            );
        }
        if let Some(value) = &self.letter_spacing {
            if let Some(value) = value {
                out.insert("ls".to_owned(), value.to_json());
            }
        }
        if let Some(value) = &self.word_spacing {
            if let Some(value) = value {
                out.insert("ws".to_owned(), value.to_json());
            }
        }
        if let Some(value) = self.text_transform {
            out.insert("tt".to_owned(), json!(value));
        }
        if let Some(value) = &self.vertical_align {
            out.insert("va".to_owned(), json!(value));
        }
        if let Some(value) = self.white_space {
            out.insert("wsp".to_owned(), json!(value));
        }
        if let Some(value) = &self.hyphens {
            out.insert("hy".to_owned(), json!(value));
        }
        out
    }

    fn box_json(&self) -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        if let Some(value) = &self.padding {
            if !is_empty_edges(value) {
                out.insert("p".to_owned(), value.to_json());
            }
        }
        if self.border.iter().any(border_has_value) {
            let mut sides = serde_json::Map::new();
            for (key, side) in ["t", "r", "b", "l"].into_iter().zip(self.border.iter()) {
                if border_has_value(side) {
                    sides.insert(key.to_owned(), side.to_json());
                }
            }
            out.insert("b".to_owned(), Value::Object(sides));
        }
        if let Some(value) = &self.background {
            if !background_is_empty(value) {
                out.insert("bg".to_owned(), value.to_json());
            }
        }
        if let Some(value) = &self.radii {
            let mut corners = serde_json::Map::new();
            for (key, value) in ["tl", "tr", "br", "bl"].into_iter().zip(value.iter()) {
                corners.insert(key.to_owned(), value.to_json());
            }
            out.insert("r".to_owned(), Value::Object(corners));
        }
        if let Some(value) = &self.box_shadow {
            if !value.is_empty() {
                out.insert(
                    "sh".to_owned(),
                    Value::Array(value.iter().map(Shadow::to_json).collect()),
                );
            }
        }
        if let Some(value) = &self.overflow {
            out.insert("o".to_owned(), json!(value));
        }
        out
    }

    fn block_json(&self) -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        if let Some(value) = self.display {
            out.insert("d".to_owned(), json!(value));
        }
        if let Some(value) = self.text_align {
            out.insert("ta".to_owned(), json!(value));
        }
        if let Some(value) = self.text_align_last {
            out.insert("tal".to_owned(), json!(value));
        }
        if let Some(value) = &self.text_indent {
            out.insert("ti".to_owned(), value.to_json());
        }
        if let Some(value) = &self.margin {
            if !is_empty_edges(value) {
                out.insert("m".to_owned(), value.to_json());
            }
        }
        if let Some(value) = self.float {
            out.insert("f".to_owned(), json!(value));
        }
        if let Some(value) = self.clear {
            out.insert("c".to_owned(), json!(value));
        }
        if let Some(value) = &self.inset {
            if !is_empty_edges(value) {
                out.insert("in".to_owned(), value.to_json());
            }
        }
        if let Some(value) = self.position {
            out.insert("pos".to_owned(), json!(value));
        }
        if let Some(value) = &self.break_before {
            out.insert("bb".to_owned(), json!(value));
        }
        if let Some(value) = &self.break_after {
            out.insert("ba".to_owned(), json!(value));
        }
        if let Some(value) = &self.break_inside {
            out.insert("bi".to_owned(), json!(value));
        }
        if let Some(kind) = self.list_style_type {
            let mut list = serde_json::Map::new();
            list.insert("t".to_owned(), json!(kind));
            if let Some(position) = self.list_style_position {
                list.insert("p".to_owned(), json!(position));
            }
            out.insert("ls".to_owned(), Value::Object(list));
        }
        out
    }

    fn size_json(&self) -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        for (key, value) in [
            ("w", &self.width),
            ("h", &self.height),
            ("minw", &self.min_width),
            ("minh", &self.min_height),
            ("maxw", &self.max_width),
            ("maxh", &self.max_height),
        ] {
            if let Some(value) = value {
                out.insert(key.to_owned(), value.to_json());
            }
        }
        if let Some(value) = self.box_sizing {
            out.insert("bs".to_owned(), json!(value));
        }
        if let Some(value) = &self.object_fit {
            out.insert("of".to_owned(), json!(value));
        }
        out
    }

    fn table_json(&self) -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        if let Some(value) = &self.border_collapse {
            out.insert("bc".to_owned(), json!(value));
        }
        if let Some(value) = &self.border_spacing {
            out.insert("bsp".to_owned(), value.to_json());
        }
        if let Some(value) = &self.table_layout {
            out.insert("tl".to_owned(), json!(value));
        }
        if let Some(value) = &self.caption_side {
            out.insert("cs".to_owned(), json!(value));
        }
        if let Some(value) = &self.empty_cells {
            out.insert("ec".to_owned(), json!(value));
        }
        out
    }
}

/// 旧 `html.rs` 使用的整数形状：单位百分之一 em，颜色 ARGB。
#[derive(Clone, Debug, Default)]
pub struct Border {
    pub width: i32,
    pub style: i32,
    pub color: u32,
}

#[derive(Clone, Debug, Default)]
pub struct Props {
    pub align: Option<i32>,
    pub indent: Option<i32>,
    pub weight: Option<i32>,
    pub italic: Option<i32>,
    pub size: Option<f64>,
    pub color: Option<u32>,
    pub background: Option<u32>,
    pub borders: [Option<Border>; 4],
    pub radius: [i64; 4],
    pub has_radius: bool,
    pub shadow: Option<[i64; 4]>,
    pub padding: [i64; 4],
    pub has_padding: bool,
    pub margins: Option<Vec<i64>>,
    pub list_style: Option<i32>,
    pub pre: bool,
    pub text_shadow: Option<[i64; 4]>,
    pub decoration: Option<i32>,
    pub letter_spacing: Option<i64>,
    pub word_spacing: Option<i64>,
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

    pub fn to_box(&self) -> Option<Vec<i64>> {
        let has_border = self.borders.iter().any(|side| side.is_some());
        let has_pad = self.padding.iter().any(|value| *value != 0);
        if self.background.is_none()
            && !has_border
            && !self.has_radius
            && self.shadow.is_none()
            && !has_pad
        {
            return None;
        }
        let width = |side: usize| self.borders[side].as_ref().map_or(0, |b| b.width) as i64;
        let border_color = self
            .borders
            .iter()
            .find_map(|side| side.as_ref().map(|b| b.color as i64))
            .unwrap_or(0);
        let shadow = self.shadow.unwrap_or([0, 0, 0, 0]);
        let style = |side: usize| self.borders[side].as_ref().map_or(1, |b| b.style) as i64;
        Some(vec![
            self.background.map_or(0, |value| value as i64),
            width(0),
            width(1),
            width(2),
            width(3),
            border_color,
            self.radius[0],
            self.radius[1],
            self.radius[2],
            self.radius[3],
            shadow[0],
            shadow[1],
            shadow[2],
            shadow[3],
            self.padding[0],
            self.padding[1],
            self.padding[2],
            self.padding[3],
            style(0),
            style(1),
            style(2),
            style(3),
        ])
    }

    pub fn box_is_visual(values: &[i64]) -> bool {
        values[0] != 0
            || values[1..5].iter().any(|width| *width != 0)
            || values[6..10].iter().any(|radius| *radius != 0)
            || values[10] != 0
            || values[11] != 0
            || values[12] != 0
    }
}

impl Computed {
    /// 把作者样式换算成旧转换器字段。只用于迁移期，不参与新样式表的去重。
    pub fn to_props(&self) -> Props {
        let mut props = Props::default();
        props.align = self.text_align.and_then(|value| match value {
            "left" | "start" => Some(1),
            "center" => Some(2),
            "right" | "end" => Some(3),
            "justify" => Some(4),
            _ => None,
        });
        if let Some(value) = &self.text_indent {
            props.indent = Some(if value.is_zero() { 0 } else { 1 });
        }
        if let Some(weight) = self.font_weight {
            props.weight = Some(if weight >= 600 { 1 } else { 2 });
        }
        if let Some(style) = self.font_style {
            props.italic = Some(if style == "italic" || style == "oblique" {
                1
            } else {
                2
            });
        }
        props.size = self.font_size_factor;
        props.color = match &self.color {
            Some(Color::Argb(value)) => Some(*value),
            _ => None,
        };
        props.background =
            self.background
                .as_ref()
                .and_then(|background| match &background.color {
                    Some(Color::Argb(value)) => Some(*value),
                    _ => None,
                });
        for (index, side) in self.border.iter().enumerate() {
            if !side.is_visible() {
                continue;
            }
            let style = match side.style.as_deref() {
                Some("dashed") => 2,
                Some("dotted") => 3,
                _ => 1,
            };
            let color = match &side.color {
                Some(Color::Argb(value)) => *value,
                _ => 0,
            };
            props.borders[index] = Some(Border {
                width: side.width_hundredths() as i32,
                style,
                color,
            });
        }
        if let Some(radii) = &self.radii {
            props.has_radius = true;
            for (index, value) in radii.iter().enumerate() {
                props.radius[index] = value.to_hundredths_em().unwrap_or(0);
            }
        }
        props.shadow = self
            .box_shadow
            .as_ref()
            .and_then(|shadows| shadows.first())
            .and_then(Shadow::legacy);
        if let Some(padding) = &self.padding {
            props.has_padding = true;
            let values = [&padding.top, &padding.right, &padding.bottom, &padding.left];
            for (index, value) in values.iter().enumerate() {
                props.padding[index] = value
                    .as_ref()
                    .and_then(Length::to_hundredths_em)
                    .unwrap_or(0);
            }
        }
        if let Some(margin) = &self.margin {
            let values = [&margin.top, &margin.right, &margin.bottom, &margin.left];
            if values.iter().any(|value| value.is_some()) {
                props.margins = Some(
                    values
                        .iter()
                        .map(|value| {
                            value
                                .as_ref()
                                .and_then(Length::to_hundredths_em)
                                .unwrap_or(0)
                        })
                        .collect(),
                );
            }
        }
        props.list_style = self.list_style_type.and_then(list_style_code);
        props.pre = self.white_space == Some("pre");
        props.text_shadow = self
            .text_shadow
            .as_ref()
            .and_then(|shadows| shadows.first())
            .and_then(Shadow::legacy);
        props.decoration = self.decoration.as_ref().map(|value| value.bits() as i32);
        props.letter_spacing = self
            .letter_spacing
            .as_ref()
            .and_then(|value| value.as_ref())
            .and_then(Length::to_hundredths_em);
        props.word_spacing = self
            .word_spacing
            .as_ref()
            .and_then(|value| value.as_ref())
            .and_then(Length::to_hundredths_em);
        props.width = self.width.as_ref().and_then(image_length);
        props.max_width = self.max_width.as_ref().and_then(image_length);
        props
    }
}

impl From<&crate::styles::Props> for Props {
    /// 旧缓存/旧测试没有有序 CSS 来源时，把旧匹配结果转成同一形状，
    /// 让 `html.rs` 只保留一套字段读取。
    fn from(old: &crate::styles::Props) -> Self {
        let mut props = Props {
            align: old.align,
            indent: old.indent,
            weight: old.weight,
            italic: old.italic,
            size: old.size,
            color: old.color,
            background: old.background,
            radius: old.radius,
            has_radius: old.has_radius,
            shadow: old.shadow,
            padding: old.padding,
            has_padding: old.has_padding,
            margins: old.margins.clone(),
            list_style: old.list_style,
            pre: old.pre,
            text_shadow: old.text_shadow,
            decoration: old.decoration,
            letter_spacing: old.letter_spacing,
            word_spacing: old.word_spacing,
            width: old.width,
            max_width: old.max_width,
            ..Default::default()
        };
        for (index, side) in old.borders.iter().enumerate() {
            props.borders[index] = side.as_ref().map(|side| Border {
                width: side.width,
                style: side.style,
                color: side.color,
            });
        }
        props
    }
}

fn image_length(value: &Length) -> Option<[i64; 2]> {
    Some(match value {
        Length::Percent(value) => [(value * 10000.0).round() as i64, 1],
        Length::Em(value) | Length::Rem(value) => [(value * 100.0).round() as i64, 2],
        Length::Px(value) => [(value * 100.0).round() as i64, 3],
        Length::Pt(value) => [(value * 4.0 / 3.0 * 100.0).round() as i64, 3],
        Length::Auto => return None,
    })
}

fn list_style_code(value: &str) -> Option<i32> {
    Some(match value {
        "none" => 0,
        "decimal" => 1,
        "lowerAlpha" => 2,
        "upperAlpha" => 3,
        "lowerRoman" => 4,
        "upperRoman" => 5,
        "disc" => 6,
        "circle" => 7,
        "square" => 8,
        _ => return None,
    })
}

fn border_has_value(side: &BorderSide) -> bool {
    side.width.is_some() || side.style.is_some() || side.color.is_some()
}

fn is_empty_edges(edges: &Edges) -> bool {
    edges.top.is_none() && edges.right.is_none() && edges.bottom.is_none() && edges.left.is_none()
}

fn background_is_empty(background: &Background) -> bool {
    background.color.is_none()
        && background.image.is_none()
        && background.repeat.is_none()
        && background.position.is_none()
        && background.size.is_none()
}

/// 绝对字号是否是 `px/pt`；用于判断是否参与用户字号缩放。
pub fn is_absolute_font_size(size: &FontSize) -> bool {
    size.unit == FontSizeUnit::Px
}
