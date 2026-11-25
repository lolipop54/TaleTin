// Copyright (c) 2026 GT Reader contributors. GPL-3.0-only, see LICENSE.
use super::{Color, parse_color, parse_length, split_top_level, split_whitespace_top_level};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Background {
    pub color: Option<Color>,
    pub image: Option<String>,
    pub gradient: Option<String>,
    pub repeat: Option<String>,
    pub position: Option<String>,
    pub size: Option<String>,
    pub attachment: Option<String>,
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
        if let Some(gradient) = &self.gradient {
            map.insert("g".to_owned(), serde_json::json!(gradient));
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
        if let Some(attachment) = &self.attachment {
            map.insert("a".to_owned(), serde_json::json!(attachment));
        }
        if let Some(raw) = &self.raw {
            map.insert("raw".to_owned(), serde_json::json!(raw));
        }
        serde_json::Value::Object(map)
    }
}

pub(crate) fn is_gradient(value: &str) -> bool {
    let Some((name, arguments)) = value.trim().split_once('(') else {
        return false;
    };
    matches!(
        name.to_ascii_lowercase().as_str(),
        "linear-gradient"
            | "radial-gradient"
            | "conic-gradient"
            | "repeating-linear-gradient"
            | "repeating-radial-gradient"
            | "repeating-conic-gradient"
    ) && arguments.ends_with(')')
}

pub fn parse_background(value: &str) -> Background {
    let mut background = Background {
        raw: Some(value.trim().to_owned()),
        ..Background::default()
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
            } else if is_gradient(&token) {
                background.gradient = Some(token);
            } else if matches!(
                lower.as_str(),
                "repeat" | "repeat-x" | "repeat-y" | "no-repeat" | "space" | "round"
            ) {
                repeats.push(lower);
            } else if matches!(lower.as_str(), "fixed" | "scroll" | "local") {
                background.attachment = Some(lower);
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
