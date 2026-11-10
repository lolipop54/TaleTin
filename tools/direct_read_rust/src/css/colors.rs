// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
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
        return parse_hex_color(hex).map(Color::Argb);
    }
    if text.starts_with("rgb") {
        return parse_rgb(&text).map(Color::Argb);
    }
    named_color(&text).map(Color::Argb)
}

fn parse_hex_color(hex: &str) -> Option<u32> {
    match hex.len() {
        3 => {
            let r = u8::from_str_radix(&hex[0..1], 16).ok()?;
            let g = u8::from_str_radix(&hex[1..2], 16).ok()?;
            let b = u8::from_str_radix(&hex[2..3], 16).ok()?;
            Some(0xFF000000 | ((r * 17) as u32) << 16 | ((g * 17) as u32) << 8 | (b * 17) as u32)
        }
        6 => u32::from_str_radix(hex, 16)
            .ok()
            .map(|value| 0xFF000000 | value),
        8 => u32::from_str_radix(hex, 16).ok(),
        _ => None,
    }
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

fn named_color(name: &str) -> Option<u32> {
    let table: HashMap<&'static str, u32> = HashMap::from([
        ("black", 0xFF000000),
        ("silver", 0xFFC0C0C0),
        ("gray", 0xFF808080),
        ("grey", 0xFF808080),
        ("white", 0xFFFFFFFF),
        ("maroon", 0xFF800000),
        ("red", 0xFFFF0000),
        ("purple", 0xFF800080),
        ("fuchsia", 0xFFFF00FF),
        ("green", 0xFF008000),
        ("lime", 0xFF00FF00),
        ("olive", 0xFF808000),
        ("yellow", 0xFFFFFF00),
        ("navy", 0xFF000080),
        ("blue", 0xFF0000FF),
        ("teal", 0xFF008080),
        ("aqua", 0xFF00FFFF),
        ("orange", 0xFFFFA500),
        ("brown", 0xFFA52A2A),
        ("pink", 0xFFFFC0CB),
        ("gold", 0xFFFFD700),
        ("beige", 0xFFF5F5DC),
        ("ivory", 0xFFFFFFF0),
        ("khaki", 0xFFF0E68C),
        ("salmon", 0xFFFA8072),
        ("crimson", 0xFFDC143C),
        ("darkred", 0xFF8B0000),
        ("darkblue", 0xFF00008B),
        ("darkgreen", 0xFF006400),
        ("darkgray", 0xFFA9A9A9),
        ("darkgrey", 0xFFA9A9A9),
        ("lightgray", 0xFFD3D3D3),
        ("lightgrey", 0xFFD3D3D3),
        ("lightblue", 0xFFADD8E6),
        ("lightgreen", 0xFF90EE90),
        ("transparent", 0x00000000),
    ]);
    table.get(name).copied()
}
