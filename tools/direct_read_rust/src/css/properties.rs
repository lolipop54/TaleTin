// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use super::shorthand::parse_four_lengths;
use super::style::Computed;
use super::value::*;
pub(super) fn parse_property(
    computed: &mut Computed,
    name: &str,
    value: &str,
    _parent: Option<&Computed>,
    parent_size: f64,
) -> bool {
    match name {
        "color" => {
            if let Some(color) = parse_color(value) {
                computed.color = Some(color);
            } else {
                return false;
            }
        }
        "font-size" => {
            let Some(size) = parse_font_size(value) else {
                return false;
            };
            computed.font_size_factor = match size.unit {
                FontSizeUnit::Em => Some(parent_size * size.value),
                FontSizeUnit::Rem => Some(size.value),
                FontSizeUnit::Px => None,
            };
            computed.font_size = Some(size);
        }
        "font-weight" => {
            let Some((weight, mode)) = parse_font_weight(value) else {
                return false;
            };
            computed.font_weight = Some(weight);
            computed.font_weight_relative = mode;
        }
        "font-style" => {
            let lower = value.to_ascii_lowercase();
            computed.font_style = match lower.as_str() {
                "normal" => Some("normal"),
                "italic" => Some("italic"),
                "oblique" => Some("oblique"),
                _ => return false,
            };
        }
        "font-family" => {
            let Some(families) = super::font_faces::families(value) else {
                return false;
            };
            computed.font_family = Some(families);
        }
        "line-height" => {
            let Some(height) = parse_line_height(value) else {
                return false;
            };
            computed.line_height = Some(height);
        }
        "text-align" => computed.text_align = text_align(value),
        "text-align-last" => computed.text_align_last = text_align(value),
        "text-indent" => {
            let Some(length) = parse_length(value) else {
                return false;
            };
            computed.text_indent = Some(length);
        }
        "text-decoration" => computed.decoration = Some(parse_decoration(value)),
        "text-shadow" => {
            let Some(shadows) = parse_shadow_list(value, false) else {
                return false;
            };
            computed.text_shadow = Some(shadows);
        }
        "letter-spacing" => {
            let Some(spacing) = parse_spacing(value) else {
                return false;
            };
            computed.letter_spacing = Some(spacing);
        }
        "word-spacing" => {
            let Some(spacing) = parse_spacing(value) else {
                return false;
            };
            computed.word_spacing = Some(spacing);
        }
        "text-transform" => {
            computed.text_transform = match value.to_ascii_lowercase().as_str() {
                "none" => Some("none"),
                "capitalize" => Some("capitalize"),
                "uppercase" => Some("uppercase"),
                "lowercase" => Some("lowercase"),
                _ => return false,
            };
        }
        "vertical-align" => {
            let lower = value.trim().to_ascii_lowercase();
            if lower == "super" || lower == "sub" {
                computed.vertical_align = Some(lower);
            } else if parse_length(value).is_some() {
                // 长度对齐暂不消费；保留原值，避免错误地当成上下标。
                computed
                    .extras
                    .insert("vertical-align".to_owned(), value.to_owned());
            } else {
                computed.vertical_align = Some(lower);
            }
        }
        "white-space" => {
            computed.white_space = match value.to_ascii_lowercase().as_str() {
                "normal" => Some("normal"),
                "pre" => Some("pre"),
                "pre-wrap" => Some("preWrap"),
                "pre-line" => Some("preLine"),
                "nowrap" => Some("nowrap"),
                "break-spaces" => Some("breakSpaces"),
                _ => return false,
            };
        }
        "hyphens" => computed.hyphens = Some(value.trim().to_ascii_lowercase()),
        "background-color" => {
            let Some(color) = parse_color(value) else {
                return false;
            };
            computed
                .background
                .get_or_insert_with(empty_background)
                .color = Some(color);
        }
        "background-image" => {
            computed
                .background
                .get_or_insert_with(empty_background)
                .image = url_value(value);
        }
        "background-repeat" => {
            computed
                .background
                .get_or_insert_with(empty_background)
                .repeat = Some(value.trim().to_ascii_lowercase());
        }
        "background-position" => {
            computed
                .background
                .get_or_insert_with(empty_background)
                .position = Some(value.trim().to_owned());
        }
        "background-size" => {
            computed
                .background
                .get_or_insert_with(empty_background)
                .size = Some(value.trim().to_ascii_lowercase());
        }
        "padding-top" | "padding-right" | "padding-bottom" | "padding-left" => {
            let Some(length) = parse_length(value) else {
                return false;
            };
            let edges = computed.padding.get_or_insert_with(empty_edges);
            match name {
                "padding-top" => edges.top = Some(length),
                "padding-right" => edges.right = Some(length),
                "padding-bottom" => edges.bottom = Some(length),
                _ => edges.left = Some(length),
            }
        }
        "top" | "right" | "bottom" | "left" => {
            let Some(length) = parse_length(value) else {
                return false;
            };
            let edges = computed.inset.get_or_insert_with(empty_edges);
            match name {
                "top" => edges.top = Some(length),
                "right" => edges.right = Some(length),
                "bottom" => edges.bottom = Some(length),
                _ => edges.left = Some(length),
            }
        }
        "margin-top" | "margin-right" | "margin-bottom" | "margin-left" => {
            let Some(length) = parse_length(value) else {
                return false;
            };
            let edges = computed.margin.get_or_insert_with(empty_edges);
            match name {
                "margin-top" => edges.top = Some(length),
                "margin-right" => edges.right = Some(length),
                "margin-bottom" => edges.bottom = Some(length),
                _ => edges.left = Some(length),
            }
        }
        "border-top-width" | "border-right-width" | "border-bottom-width" | "border-left-width" => {
            let Some(width) = parse_border_width(value) else {
                return false;
            };
            let index = border_index(name);
            computed.border[index].width = Some(width);
        }
        "border-top-style" | "border-right-style" | "border-bottom-style" | "border-left-style" => {
            let index = border_index(name);
            computed.border[index].style = Some(value.trim().to_ascii_lowercase());
        }
        "border-top-color" | "border-right-color" | "border-bottom-color" | "border-left-color" => {
            let Some(color) = parse_color(value) else {
                return false;
            };
            let index = border_index(name);
            computed.border[index].color = Some(color);
        }
        "border-top-left-radius"
        | "border-top-right-radius"
        | "border-bottom-right-radius"
        | "border-bottom-left-radius" => {
            let Some(radius) = parse_length(value) else {
                return false;
            };
            let index = match name {
                "border-top-left-radius" => 0,
                "border-top-right-radius" => 1,
                "border-bottom-right-radius" => 2,
                _ => 3,
            };
            computed.radii.get_or_insert_with(|| {
                [
                    Length::Px(0.0),
                    Length::Px(0.0),
                    Length::Px(0.0),
                    Length::Px(0.0),
                ]
            })[index] = radius;
        }
        "border-radius" => {
            let Some(values) = parse_radii(value) else {
                return false;
            };
            computed.radii = Some(values);
        }
        "box-shadow" => {
            let Some(shadows) = parse_shadow_list(value, true) else {
                return false;
            };
            computed.box_shadow = Some(shadows);
        }
        "display" => {
            computed.display = display(value);
        }
        "float" => {
            computed.float = keyword(
                value,
                &["none", "left", "right", "inline-start", "inline-end"],
            )
        }
        "clear" => computed.clear = keyword(value, &["none", "left", "right", "both"]),
        "position" => {
            computed.position = keyword(
                value,
                &["static", "relative", "absolute", "fixed", "sticky"],
            )
        }
        "list-style-type" => {
            computed.list_style_type = list_style_type(&value.to_ascii_lowercase())
        }
        "list-style-position" => {
            computed.list_style_position = match value.to_ascii_lowercase().as_str() {
                "inside" => Some("inside"),
                "outside" => Some("outside"),
                _ => return false,
            }
        }
        "break-before" | "break-after" | "break-inside" => {
            let field = match name {
                "break-before" => &mut computed.break_before,
                "break-after" => &mut computed.break_after,
                _ => &mut computed.break_inside,
            };
            *field = Some(value.trim().to_ascii_lowercase());
        }
        "width" | "height" | "min-width" | "min-height" | "max-width" | "max-height" => {
            let Some(length) = parse_length(value) else {
                return false;
            };
            match name {
                "width" => computed.width = Some(length),
                "height" => computed.height = Some(length),
                "min-width" => computed.min_width = Some(length),
                "min-height" => computed.min_height = Some(length),
                "max-width" => computed.max_width = Some(length),
                _ => computed.max_height = Some(length),
            }
        }
        "box-sizing" => {
            computed.box_sizing = match value.to_ascii_lowercase().as_str() {
                "content-box" => Some("contentBox"),
                "border-box" => Some("borderBox"),
                _ => return false,
            }
        }
        "object-fit" => computed.object_fit = Some(value.trim().to_ascii_lowercase()),
        "border-collapse" | "table-layout" | "caption-side" | "empty-cells" => {
            let slot = match name {
                "border-collapse" => &mut computed.border_collapse,
                "table-layout" => &mut computed.table_layout,
                "caption-side" => &mut computed.caption_side,
                _ => &mut computed.empty_cells,
            };
            *slot = Some(value.trim().to_ascii_lowercase());
        }
        "border-spacing" => {
            let Some(length) = parse_length(value) else {
                return false;
            };
            computed.border_spacing = Some(length);
        }
        "overflow" => computed.overflow = Some(value.trim().to_ascii_lowercase()),
        // 已登记但当前布局不消费的属性：保留原值用于诊断，不假装已实现。
        _ => {
            computed.extras.insert(name.to_owned(), value.to_owned());
        }
    }
    true
}

fn text_align(value: &str) -> Option<&'static str> {
    Some(match value.trim().to_ascii_lowercase().as_str() {
        // 书写方向目前只支持 LTR：start→left、end→right，旧排版层只认左右中。
        "start" => "left",
        "end" => "right",
        "left" => "left",
        "right" => "right",
        "center" => "center",
        "justify" | "justify-all" => "justify",
        _ => return None,
    })
}

fn display(value: &str) -> Option<&'static str> {
    Some(match value.trim().to_ascii_lowercase().as_str() {
        "block" => "block",
        "inline" => "inline",
        "inline-block" => "inlineBlock",
        "list-item" => "listItem",
        "table" => "table",
        "inline-table" => "inlineTable",
        "table-row-group" => "tableRowGroup",
        "table-header-group" => "tableHeaderGroup",
        "table-footer-group" => "tableFooterGroup",
        "table-row" => "tableRow",
        "table-cell" => "tableCell",
        "table-caption" => "tableCaption",
        "table-column-group" => "tableColumnGroup",
        "table-column" => "tableColumn",
        "flex" => "flex",
        "inline-flex" => "inlineFlex",
        "grid" => "grid",
        "inline-grid" => "inlineGrid",
        "flow-root" => "flowRoot",
        "none" => "none",
        "contents" => "contents",
        _ => return None,
    })
}

fn keyword(value: &str, allowed: &[&'static str]) -> Option<&'static str> {
    let lower = value.trim().to_ascii_lowercase();
    allowed.iter().copied().find(|item| *item == lower)
}

fn border_index(name: &str) -> usize {
    if name.contains("right") {
        1
    } else if name.contains("bottom") {
        2
    } else if name.contains("left") {
        3
    } else {
        0
    }
}

pub(super) fn parse_radii(value: &str) -> Option<[Length; 4]> {
    let values: Vec<Length> = value.split_whitespace().filter_map(parse_length).collect();
    Some(match values.as_slice() {
        [all] => [all.clone(), all.clone(), all.clone(), all.clone()],
        [first, second] => [first.clone(), second.clone(), first.clone(), second.clone()],
        [first, second, third] => [first.clone(), second.clone(), third.clone(), second.clone()],
        [first, second, third, fourth] => {
            [first.clone(), second.clone(), third.clone(), fourth.clone()]
        }
        _ => return None,
    })
}

fn url_value(value: &str) -> Option<String> {
    super::value::parse_url(value)
}

fn empty_background() -> Background {
    Background {
        color: None,
        image: None,
        repeat: None,
        position: None,
        size: None,
        raw: None,
    }
}

fn empty_edges() -> Edges {
    Edges {
        top: None,
        right: None,
        bottom: None,
        left: None,
    }
}

fn parse_spacing(value: &str) -> Option<Option<Length>> {
    super::value::parse_spacing(value)
}
