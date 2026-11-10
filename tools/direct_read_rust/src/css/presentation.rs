//! HTML 旧式字号是作者的低优先级显示提示，不能覆盖样式表或行内 CSS。
use crate::dom::{Handle, attr, tag};

/// HTML 表现属性与 font[size] 共用低优先级来源；作者 CSS 仍可覆盖。
pub(super) fn hints(node: &Handle) -> Vec<(&'static str, String)> {
    let mut result = Vec::new();
    // hidden 的空章题也不能留下外边距。作者显式 display 仍可覆盖此提示。
    if attr(node, "hidden").is_some() {
        result.push(("display", "none".to_owned()));
    }
    // 原书宿主页把 p 的旧式 -webkit-center/right 当作普通正文处理；
    // 简化模式沿用这一约定。CSS 的 text-align 及 h1-h6 的 align 仍保留。
    if tag(node) != "p" && let Some(value) = attr(node, "align") {
        if matches!(value.trim().to_ascii_lowercase().as_str(), "left" | "right" | "center" | "justify") {
            result.push(("text-align", value));
        }
    }
    if tag(node) == "font" {
        if let Some(value) = attr(node, "color") {
            result.push(("color", value));
        }
    }
    result
}

pub(super) fn font_size(node: &Handle, reader_font: f64) -> Option<String> {
    if tag(node) != "font" {
        return None;
    }
    let raw = attr(node, "size")?;
    let value = raw.trim();
    let number = value.parse::<i32>().ok()?;
    let size = if value.starts_with(['+', '-']) {
        3i32.saturating_add(number)
    } else {
        number
    }
    .clamp(1, 7);
    // 第3档等于正文字号，其余档采用固定像素差；每次正式排版按当前字号重算。
    // 这里只生成本次环境下的根字号倍数，继续共用既有层叠、继承和片段测量。
    let delta = [-2.0, -1.0, 0.0, 1.0, 2.0, 4.0, 6.0][(size - 1) as usize];
    Some(format!("{}rem", (reader_font + delta) / reader_font))
}
