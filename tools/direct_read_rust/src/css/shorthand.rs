// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use super::value::*;
const BORDER_SIDES: [&str; 4] = ["top", "right", "bottom", "left"];
pub(super) fn expand_declaration(name: &str, value: &str) -> Vec<(String, String)> {
    let trimmed = value.trim();
    let keys = longhands(name);
    if name == "background" && trimmed == "none" {
        return keys
            .into_iter()
            .map(|key| (key, "initial".to_owned()))
            .collect();
    }
    if matches!(
        trimmed,
        "initial" | "inherit" | "unset" | "revert" | "revert-layer"
    ) {
        return keys
            .into_iter()
            .map(|key| (key, trimmed.to_owned()))
            .collect();
    }
    let expanded = match name {
        "margin" | "padding" => {
            let sides = parse_four_lengths(trimmed);
            let Some(sides) = sides else {
                return vec![];
            };
            let keys = if name == "margin" {
                ["margin-top", "margin-right", "margin-bottom", "margin-left"]
            } else {
                [
                    "padding-top",
                    "padding-right",
                    "padding-bottom",
                    "padding-left",
                ]
            };
            keys.into_iter()
                .zip(sides)
                .map(|(key, value)| (key.to_owned(), length_to_css(&value)))
                .collect()
        }
        "border-radius" => {
            let Some(values) = super::properties::parse_radii(trimmed) else {
                return vec![];
            };
            [
                "border-top-left-radius",
                "border-top-right-radius",
                "border-bottom-right-radius",
                "border-bottom-left-radius",
            ]
            .into_iter()
            .zip(values)
            .map(|(key, value)| (key.to_owned(), length_to_css(&value)))
            .collect()
        }
        "border" => expand_border_side(trimmed, None),
        "border-top" => expand_border_side(trimmed, Some("top")),
        "border-right" => expand_border_side(trimmed, Some("right")),
        "border-bottom" => expand_border_side(trimmed, Some("bottom")),
        "border-left" => expand_border_side(trimmed, Some("left")),
        "border-width" | "border-style" | "border-color" => {
            let raw_values = split_whitespace_top_level(trimmed);
            let values: Vec<&str> = raw_values.iter().map(String::as_str).collect();
            let four = four_values(&values);
            let Some(four) = four else {
                return vec![];
            };
            let suffix = if name == "border-width" {
                "width"
            } else if name == "border-style" {
                "style"
            } else {
                "color"
            };
            BORDER_SIDES
                .into_iter()
                .zip(four)
                .map(|(side, value)| {
                    (
                        format!("border-{side}-{suffix}"),
                        if suffix == "color" {
                            value.to_owned()
                        } else if suffix == "width" {
                            format_border_width(value)
                        } else {
                            value.to_owned()
                        },
                    )
                })
                .collect()
        }
        "background" => {
            let background = parse_background(trimmed);
            let mut result = Vec::new();
            if let Some(color) = &background.color {
                result.push(("background-color".to_owned(), color_to_css(color)));
            }
            if let Some(image) = &background.image {
                result.push((
                    "background-image".to_owned(),
                    format!("url({})", serde_json::to_string(image).unwrap()),
                ));
            }
            if let Some(repeat) = &background.repeat {
                result.push(("background-repeat".to_owned(), repeat.clone()));
            }
            if let Some(position) = &background.position {
                result.push(("background-position".to_owned(), position.clone()));
            }
            if let Some(size) = &background.size {
                result.push(("background-size".to_owned(), size.clone()));
            }
            result
        }
        "font" => expand_font(trimmed),
        "list-style" => {
            let Some((kind, position)) = parse_list_style(trimmed) else {
                return vec![];
            };
            let mut result = Vec::new();
            if let Some(kind) = kind {
                result.push(("list-style-type".to_owned(), kind.to_owned()));
            }
            if let Some(position) = position {
                result.push(("list-style-position".to_owned(), position.to_owned()));
            }
            result
        }
        _ => vec![(name.to_owned(), trimmed.to_owned())],
    };
    if expanded.is_empty() {
        return expanded;
    }
    if keys.len() == 1 {
        return expanded;
    }
    // 简写必须重置未写出的子属性，不能遗留之前的 italic/background-image 等。
    let mut result: Vec<_> = keys
        .into_iter()
        .map(|key| (key, "initial".to_owned()))
        .collect();
    result.extend(expanded);
    result
}

fn expand_border_side(value: &str, only: Option<&str>) -> Vec<(String, String)> {
    let parsed = parse_border_side(value);
    let sides: Vec<&str> = only.map_or(BORDER_SIDES.to_vec(), |side| vec![side]);
    let mut result = Vec::new();
    for side in sides {
        if let Some(width) = &parsed.width {
            result.push((format!("border-{side}-width"), length_to_css(width)));
        }
        if let Some(style) = &parsed.style {
            result.push((format!("border-{side}-style"), style.clone()));
        }
        if let Some(color) = &parsed.color {
            result.push((format!("border-{side}-color"), color_to_css(color)));
        }
    }
    result
}

fn expand_font(value: &str) -> Vec<(String, String)> {
    let tokens = split_whitespace_top_level(value);
    let mut result = Vec::new();
    let mut size = None;
    let mut line_height = None;
    let mut family_start = None;
    for (index, token) in tokens.iter().enumerate() {
        let lower = token.to_ascii_lowercase();
        if lower == "italic" || lower == "oblique" {
            result.push(("font-style".to_owned(), lower));
            continue;
        }
        if lower == "normal" {
            continue;
        }
        if let Some((weight, _)) = parse_font_weight(&lower) {
            if lower.chars().all(|ch| ch.is_ascii_digit())
                || lower == "bold"
                || lower == "bolder"
                || lower == "lighter"
            {
                result.push(("font-weight".to_owned(), lower));
                let _ = weight;
                continue;
            }
        }
        let (size_token, line) = match token.split_once('/') {
            Some((size, line)) => (size, Some(line.to_owned())),
            None => (token.as_str(), None),
        };
        if let Some(parsed) = parse_font_size(size_token) {
            size = Some(parsed);
            line_height = line;
            family_start = Some(index + 1);
            continue;
        }
    }
    if let Some(size) = size {
        result.push(("font-size".to_owned(), font_size_to_css(&size)));
        if let Some(line) = line_height {
            result.push(("line-height".to_owned(), line));
        }
        if let Some(start) = family_start {
            let family = tokens[start..].join(" ");
            if !family.is_empty() {
                result.push(("font-family".to_owned(), family));
            }
        }
    }
    result
}

pub(super) fn parse_four_lengths(value: &str) -> Option<[Length; 4]> {
    let values: Vec<Length> = split_whitespace_top_level(value)
        .into_iter()
        .map(|value| parse_length(&value))
        .collect::<Option<Vec<_>>>()?;
    Some(match values.as_slice() {
        [all] => [all.clone(), all.clone(), all.clone(), all.clone()],
        [vertical, horizontal] => [
            vertical.clone(),
            horizontal.clone(),
            vertical.clone(),
            horizontal.clone(),
        ],
        [top, horizontal, bottom] => [
            top.clone(),
            horizontal.clone(),
            bottom.clone(),
            horizontal.clone(),
        ],
        [top, right, bottom, left] => [top.clone(), right.clone(), bottom.clone(), left.clone()],
        _ => return None,
    })
}

fn four_values<'a>(values: &[&'a str]) -> Option<[&'a str; 4]> {
    Some(match values {
        [all] => [all, all, all, all],
        [vertical, horizontal] => [vertical, horizontal, vertical, horizontal],
        [top, horizontal, bottom] => [top, horizontal, bottom, horizontal],
        [top, right, bottom, left] => [top, right, bottom, left],
        _ => return None,
    })
}

fn length_to_css(value: &Length) -> String {
    match value {
        Length::Em(v) => format!("{v}em"),
        Length::Rem(v) => format!("{v}rem"),
        Length::Percent(v) => format!("{}%", v * 100.0),
        Length::Px(v) => format!("{v}px"),
        Length::Pt(v) => format!("{v}pt"),
        Length::Auto => "auto".to_owned(),
    }
}

fn font_size_to_css(value: &FontSize) -> String {
    match value.unit {
        FontSizeUnit::Em => format!("{}em", value.value),
        FontSizeUnit::Rem => format!("{}rem", value.value),
        FontSizeUnit::Px => format!("{}px", value.value),
    }
}

fn color_to_css(value: &Color) -> String {
    match value {
        Color::Argb(argb) => format!("#{argb:08x}"),
        Color::Current => "currentColor".to_owned(),
    }
}

fn format_border_width(value: &str) -> String {
    match value {
        "thin" => "1px".to_owned(),
        "medium" => "3px".to_owned(),
        "thick" => "5px".to_owned(),
        other => other.to_owned(),
    }
}

fn longhands(name: &str) -> Vec<String> {
    if name == "border-radius" {
        return [
            "border-top-left-radius",
            "border-top-right-radius",
            "border-bottom-right-radius",
            "border-bottom-left-radius",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
    }
    match name {
        "margin" | "padding" => BORDER_SIDES
            .iter()
            .map(|side| format!("{name}-{side}"))
            .collect(),
        "border" => BORDER_SIDES
            .iter()
            .flat_map(|side| {
                ["width", "style", "color"].map(|part| format!("border-{side}-{part}"))
            })
            .collect(),
        "border-top" | "border-right" | "border-bottom" | "border-left" => {
            ["width", "style", "color"]
                .map(|part| format!("{name}-{part}"))
                .to_vec()
        }
        "border-width" | "border-style" | "border-color" => BORDER_SIDES
            .iter()
            .map(|side| format!("border-{side}-{}", name.trim_start_matches("border-")))
            .collect(),
        "font" => [
            "font-size",
            "font-weight",
            "font-style",
            "font-family",
            "line-height",
        ]
        .map(str::to_owned)
        .to_vec(),
        "background" => [
            "background-color",
            "background-image",
            "background-repeat",
            "background-position",
            "background-size",
        ]
        .map(str::to_owned)
        .to_vec(),
        "list-style" => ["list-style-type", "list-style-position"]
            .map(str::to_owned)
            .to_vec(),
        _ => vec![name.to_owned()],
    }
}
