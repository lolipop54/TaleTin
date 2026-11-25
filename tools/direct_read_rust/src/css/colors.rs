// Copyright (c) 2026 GT Reader contributors. GPL-3.0-only, see LICENSE.
use super::*;

pub fn parse_color(value: &str) -> Option<Color> {
    let text = value.trim().to_ascii_lowercase();
    if text == "currentcolor" {
        return Some(Color::Current);
    }
    if text == "transparent" {
        return Some(Color::Argb(0));
    }
    if let Some(hex) = text.strip_prefix('#') {
        let (r, g, b, alpha) = cssparser::color::parse_hash_color(hex.as_bytes()).ok()?;
        return Some(Color::Argb(u32::from_be_bytes([
            (alpha * 255.0).round() as u8,
            r,
            g,
            b,
        ])));
    }
    if text.starts_with("rgb") {
        return parse_rgb(&text).map(Color::Argb);
    }
    let (r, g, b) = cssparser::color::parse_named_color(&text).ok()?;
    Some(Color::Argb(u32::from_be_bytes([255, r, g, b])))
}

fn parse_rgb(text: &str) -> Option<u32> {
    let open = text.find('(')?;
    let close = text.rfind(')')?;
    let body = &text[open + 1..close];
    let parts: Vec<&str> = body
        .split(|ch: char| ch == ',' || ch == '/' || ch.is_whitespace())
        .filter(|part| !part.is_empty())
        .collect();
    if parts.len() < 3 {
        return None;
    }
    let channel = |value: &str| -> Option<u32> {
        if let Some(percent) = value.strip_suffix('%') {
            let percent = percent.parse::<f64>().ok()?;
            Some((percent / 100.0 * 255.0).round().clamp(0.0, 255.0) as u32)
        } else {
            value
                .parse::<f64>()
                .ok()
                .map(|value| value.round().clamp(0.0, 255.0) as u32)
        }
    };
    let r = channel(parts[0])?;
    let g = channel(parts[1])?;
    let b = channel(parts[2])?;
    let alpha = parts
        .get(3)
        .and_then(|value| {
            if let Some(percent) = value.strip_suffix('%') {
                percent
                    .parse::<f64>()
                    .ok()
                    .map(|v| (v / 100.0 * 255.0).round() as u32)
            } else {
                value
                    .parse::<f64>()
                    .ok()
                    .map(|v| (v * 255.0).round() as u32)
            }
        })
        .unwrap_or(255)
        .clamp(0, 255);
    Some((alpha << 24) | (r << 16) | (g << 8) | b)
}

#[cfg(test)]
mod alpha_tests {
    use super::*;

    #[test]
    fn css_hex_alpha_is_the_last_channel() {
        assert_eq!(parse_color("#1357"), Some(Color::Argb(0x77113355)));
        assert_eq!(parse_color("#2468ac80"), Some(Color::Argb(0x802468ac)));
        assert_eq!(parse_color("#字"), None);
        assert_eq!(parse_color("RebeccaPurple"), Some(Color::Argb(0xff663399)));
        assert_eq!(parse_color("AliceBlue"), Some(Color::Argb(0xfff0f8ff)));
    }
}
