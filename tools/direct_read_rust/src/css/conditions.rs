// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 条件按实际单纸面求值；supports 只承认 Flutter 当前能显示的能力。
use super::{properties::parse_property, style::Computed, value::split_top_level};
use serde_json::Value;
#[derive(Clone, Debug)]
pub struct Environment {
    pub width: f64,
    pub height: f64,
    pub font: f64,
    pub dark: bool,
}
impl Default for Environment {
    fn default() -> Self {
        Self {
            width: 360.,
            height: 760.,
            font: 16.,
            dark: false,
        }
    }
}
impl Environment {
    pub fn from_json(value: &Value) -> Self {
        let base = Self::default();
        Self {
            width: value["width"].as_f64().unwrap_or(base.width),
            height: value["height"].as_f64().unwrap_or(base.height),
            font: value["fontSize"].as_f64().unwrap_or(base.font),
            dark: value["dark"].as_bool().unwrap_or(false),
        }
    }
    pub fn matches(&self, kind: &str, expression: &str) -> bool {
        evaluate(expression, &|feature| {
            if kind == "media" {
                self.media(feature)
            } else {
                supports(feature)
            }
        })
    }
    fn media(&self, feature: &str) -> bool {
        let feature = feature.trim().to_ascii_lowercase();
        if let Some((name, value)) = feature.split_once(':') {
            let name = name.trim();
            let value = value.trim();
            if name == "orientation" {
                return if value == "landscape" {
                    self.width > self.height
                } else {
                    value == "portrait" && self.width <= self.height
                };
            }
            if name == "prefers-color-scheme" {
                return value == if self.dark { "dark" } else { "light" };
            }
            if name == "hover" {
                return value == "none";
            }
            if name == "pointer" {
                return value == "coarse";
            }
            let (comparison, name) = if let Some(name) = name.strip_prefix("min-") {
                (1, name)
            } else if let Some(name) = name.strip_prefix("max-") {
                (-1, name)
            } else {
                (0, name)
            };
            let actual = match name {
                "width" => self.width,
                "height" => self.height,
                _ => return false,
            };
            let Some(expected) = self.pixels(value) else {
                return false;
            };
            return match comparison {
                1 => actual >= expected,
                -1 => actual <= expected,
                _ => (actual - expected).abs() < 0.01,
            };
        }
        // Media Queries 4 的范围写法，包含双边比较。
        let tokens = feature
            .replace("<=", " ≤ ")
            .replace(">=", " ≥ ")
            .replace('<', " < ")
            .replace('>', " > ")
            .replace('=', " = ");
        let tokens: Vec<_> = tokens.split_whitespace().collect();
        if tokens.len() == 3 || tokens.len() == 5 {
            let number = |value: &str| match value {
                "width" => Some(self.width),
                "height" => Some(self.height),
                _ => self.pixels(value),
            };
            let compare = |a: &str, op: &str, b: &str| {
                let (Some(a), Some(b)) = (number(a), number(b)) else {
                    return false;
                };
                match op {
                    "<" => a < b,
                    "≤" => a <= b,
                    ">" => a > b,
                    "≥" => a >= b,
                    "=" => a == b,
                    _ => false,
                }
            };
            return compare(tokens[0], tokens[1], tokens[2])
                && (tokens.len() == 3 || compare(tokens[2], tokens[3], tokens[4]));
        }
        matches!(feature.as_str(), "all" | "screen")
    }
    fn pixels(&self, value: &str) -> Option<f64> {
        let value = value.trim();
        for (unit, factor) in [
            ("rem", self.font),
            ("em", self.font),
            ("px", 1.),
            ("pt", 4. / 3.),
        ] {
            if let Some(number) = value.strip_suffix(unit) {
                return number.trim().parse::<f64>().ok().map(|v| v * factor);
            }
        }
        if value == "0" { Some(0.) } else { None }
    }
}
fn supports(feature: &str) -> bool {
    let Some((name, value)) = feature.split_once(':') else {
        return false;
    };
    let name = name.trim().to_ascii_lowercase();
    let value = value.trim();
    // 能解析、能存储不等于能显示。未实现的定位、Flex/Grid、浮动等不能返回 true。
    match name.as_str() {
        "display" => {
            return matches!(
                value,
                "block"
                    | "inline"
                    | "inline-block"
                    | "list-item"
                    | "table"
                    | "table-row"
                    | "table-cell"
                    | "table-row-group"
                    | "table-header-group"
                    | "table-footer-group"
                    | "table-caption"
            );
        }
        "position" => return value == "static",
        "float" | "clear" => return value == "none",
        "background-image" => return value == "none" || super::value::parse_url(value).is_some(),
        _ => {}
    }
    // 只读注册表里已经有显示消费方的属性。parse_property 会为诊断保留
    // 未知属性原值，所以它的 true 不能直接作为支持能力。
    let implemented = crate::style_tables_generated::STYLE_PROPERTIES
        .iter()
        .any(|p| p.name == name && matches!(p.status, "rendered" | "verified"));
    if !implemented {
        return false;
    }
    let mut computed = Computed::default();
    parse_property(&mut computed, &name, value, None, 1.) && computed.extras.is_empty()
}
fn evaluate(expression: &str, feature: &impl Fn(&str) -> bool) -> bool {
    let mut expression = expression.trim();
    if let Some(rest) = expression.strip_prefix("only ") {
        expression = rest.trim();
    }
    let comma = split_top_level(expression, ',');
    if comma.len() > 1 {
        return comma.iter().any(|part| evaluate(part, feature));
    }
    for operator in ["or", "and"] {
        let parts = split_boolean(expression, operator);
        if parts.len() > 1 {
            return if operator == "or" {
                parts.iter().any(|part| evaluate(part, feature))
            } else {
                parts.iter().all(|part| evaluate(part, feature))
            };
        }
    }
    if let Some(rest) = expression.strip_prefix("not ") {
        return !evaluate(rest, feature);
    }
    if expression.starts_with('(') && outer_parentheses(expression) {
        let inner = &expression[1..expression.len() - 1];
        if inner.contains(':')
            && split_boolean(inner, "and").len() == 1
            && split_boolean(inner, "or").len() == 1
        {
            return feature(inner);
        }
        return evaluate(inner, feature);
    }
    feature(expression)
}
fn outer_parentheses(value: &str) -> bool {
    let mut depth = 0;
    for (index, ch) in value.char_indices() {
        if ch == '(' {
            depth += 1;
        } else if ch == ')' {
            depth -= 1;
            if depth == 0 && index + 1 < value.len() {
                return false;
            }
        }
    }
    depth == 0
}
fn split_boolean<'a>(value: &'a str, operator: &str) -> Vec<&'a str> {
    let marker = format!(" {operator} ");
    let mut depth = 0;
    let mut start = 0;
    let mut result = vec![];
    for (index, ch) in value.char_indices() {
        if ch == '(' {
            depth += 1;
        } else if ch == ')' {
            depth -= 1;
        }
        if depth == 0 && value[index..].starts_with(&marker) {
            result.push(&value[start..index]);
            start = index + marker.len();
        }
    }
    result.push(&value[start..]);
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn actual_paper_and_capability_conditions() {
        let e = Environment {
            width: 300.,
            height: 600.,
            font: 16.,
            dark: true,
        };
        assert!(e.matches(
            "media",
            "screen and (max-width:320px) and (orientation:portrait)"
        ));
        assert!(e.matches("media", "(200px <= width < 400px)"));
        assert!(e.matches("media", "(prefers-color-scheme:dark)"));
        assert!(!e.matches("media", "print"));
        assert!(!e.matches("supports", "(display:grid)"));
        assert!(e.matches("supports", "(color:red) and not (display:flex)"));
    }
}
