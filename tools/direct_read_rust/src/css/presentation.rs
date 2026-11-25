//! HTML 表现属性按元素语义进入作者样式之前的层叠；不修改正文或源 DOM。
use crate::dom::{Handle, attr, tag};
use std::collections::{HashMap, HashSet};

pub(super) type Hints = Vec<(&'static str, String)>;

pub(super) fn keyword(n: &Handle, key: &str) -> String {
    attr(n, key).unwrap_or_default().trim().to_ascii_lowercase()
}

// HTML 尺寸算法读取开头的十进制数；例如有些制书器把闭合斜线粘在 size=1 后面。
pub(super) fn dimension(raw: &str, percent: bool) -> Option<String> {
    let s = raw.trim_start();
    let s = s.strip_prefix('+').unwrap_or(s);
    if !s.as_bytes().first()?.is_ascii_digit() {
        return None;
    }
    let int = s.bytes().take_while(u8::is_ascii_digit).count();
    let end = if s[int..].starts_with('.') {
        int + 1 + s[int + 1..].bytes().take_while(u8::is_ascii_digit).count()
    } else {
        int
    };
    let number = s[..end].parse::<f64>().ok().filter(|v| v.is_finite())?;
    Some(format!(
        "{number}{}",
        if percent && s[end..].starts_with('%') {
            "%"
        } else {
            "px"
        }
    ))
}

fn mobi_length(raw: &str, signed: bool) -> Option<String> {
    let s = raw.trim().to_ascii_lowercase();
    let end = s
        .find(|c: char| !(c.is_ascii_digit() || matches!(c, '+' | '-' | '.')))
        .unwrap_or(s.len());
    let number = s[..end].parse::<f64>().ok()?;
    if !number.is_finite() || number < 0.0 && !signed {
        return None;
    }
    let unit = match &s[end..] {
        "" => "px",
        u @ ("px" | "em" | "pt" | "%") => u,
        _ => return None,
    };
    Some(format!("{number}{unit}"))
}

/// 旧 HTML 颜色有自己的算法（例如无井号的十六进制）；CSS 颜色解析保持原样。
pub(super) fn color(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("transparent") {
        return None;
    }
    if cssparser::color::parse_named_color(s).is_ok()
        || matches!(s.len(), 4 | 7)
            && s.starts_with('#')
            && s[1..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Some(s.to_owned());
    }
    let mut hex = String::with_capacity(s.len().min(128));
    for c in s.chars() {
        if hex.len() >= 128 {
            break;
        }
        if c as u32 > 0xffff {
            hex.push('0');
            if hex.len() < 128 {
                hex.push('0');
            }
        } else {
            hex.push(if c.is_ascii_hexdigit() || hex.is_empty() && c == '#' {
                c
            } else {
                '0'
            });
        }
    }
    if hex.starts_with('#') {
        hex.remove(0);
    }
    while hex.is_empty() || hex.len() % 3 != 0 {
        hex.push('0');
    }
    let n = hex.len() / 3;
    let rgb = [&hex[..n], &hex[n..2 * n], &hex[2 * n..]];
    let mut start = n.saturating_sub(8);
    while n - start > 2 && rgb.iter().all(|s| s.as_bytes()[start] == b'0') {
        start += 1;
    }
    Some(format!(
        "#{:02x}{:02x}{:02x}",
        channel(rgb[0], start),
        channel(rgb[1], start),
        channel(rgb[2], start)
    ))
}
fn channel(s: &str, i: usize) -> u8 {
    u8::from_str_radix(&s[i..s.len().min(i + 2)], 16).unwrap_or(0)
}

fn position(h: &mut Hints, side: &str) {
    if matches!(side, "left" | "center" | "right") {
        h.push((
            "margin-left",
            if side == "left" { "0" } else { "auto" }.into(),
        ));
        h.push((
            "margin-right",
            if side == "right" { "0" } else { "auto" }.into(),
        ));
    }
}

pub(super) fn hints(n: &Handle, mobi: bool, path: &str, resources: &mut HashSet<String>) -> Hints {
    let t = tag(n);
    let mut h = Hints::new();
    if mobi && t == "mbp:pagebreak" {
        // MOBI 经常省略结束标签；HTML 解析器会把后文挂在这个节点下面。
        // 断点只取开始标签的位置，把节点变成块会让每一段都产生多余的行边界。
        h.push(("break-before", "page".into()));
    }
    if n.attrs.borrow().is_empty() {
        return h;
    }
    if attr(n, "hidden").is_some() {
        h.push(("display", "none".into()));
    }
    if let Some(dir) = attr(n, "dir") {
        let dir = dir.trim().to_ascii_lowercase();
        if dir == "auto" {
            h.push(("direction", crate::dom::auto_direction(n).into()));
        } else if matches!(dir.as_str(), "ltr" | "rtl") {
            h.push(("direction", dir));
        }
    }
    let align = keyword(n, "align");
    let paragraph = matches!(t, "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6");
    let mobi_block = mobi
        && matches!(
            t,
            "p" | "div"
                | "blockquote"
                | "li"
                | "ol"
                | "ul"
                | "h1"
                | "h2"
                | "h3"
                | "h4"
                | "h5"
                | "h6"
        );
    let table_part = matches!(
        t,
        "thead" | "tbody" | "tfoot" | "tr" | "th" | "td" | "col" | "colgroup"
    );
    if paragraph || mobi_block || table_part {
        if matches!(align.as_str(), "left" | "right" | "center" | "justify")
            || table_part && align == "char"
        {
            h.push(("text-align", align.clone()));
        }
    }
    if table_part {
        let v = keyword(n, "valign");
        if matches!(v.as_str(), "top" | "bottom" | "middle" | "baseline") {
            h.push(("vertical-align", v));
        }
    }
    if t == "img" {
        match align.as_str() {
            "left" | "right" => h.push(("float", align)),
            "middle" | "center" => h.push(("vertical-align", "legacy-center".into())),
            "absmiddle" | "abscenter" => h.push(("vertical-align", "middle".into())),
            "texttop" => h.push(("vertical-align", "text-top".into())),
            "absbottom" => h.push(("vertical-align", "bottom".into())),
            "bottom" | "baseline" => h.push(("vertical-align", "baseline".into())),
            "top" => h.push(("vertical-align", "top".into())),
            _ => {}
        }
        for (a, b, c) in [
            ("hspace", "margin-left", "margin-right"),
            ("vspace", "margin-top", "margin-bottom"),
        ] {
            if let Some(v) = attr(n, a).and_then(|s| dimension(&s, false)) {
                h.push((b, v.clone()));
                h.push((c, v));
            }
        }
    } else if t == "table" {
        match align.as_str() {
            "center" => position(&mut h, "center"),
            "left" | "right" => h.push(("float", align)),
            _ => {}
        }
    } else if t == "hr" || t == "legend" {
        position(&mut h, &align);
    } else if t == "caption" && matches!(align.as_str(), "top" | "bottom" | "left" | "right") {
        h.push(("caption-side", align));
    }

    for (key, applies) in [
        (
            "width",
            matches!(t, "img" | "hr" | "table" | "td" | "th" | "col" | "colgroup"),
        ),
        (
            "height",
            matches!(
                t,
                "img" | "table" | "tr" | "td" | "th" | "thead" | "tbody" | "tfoot"
            ),
        ),
    ] {
        if applies
            && let Some(raw) = attr(n, key)
            && !raw.trim_end().ends_with('*')
            && let Some(v) = dimension(&raw, true)
        {
            h.push((key, v));
        }
    }
    if mobi_block {
        if let Some(indent) = attr(n, "width").and_then(|s| mobi_length(&s, true)) {
            // 负缩进是悬挂排版。整段右移相同距离，首行仍在纸面内。
            if let Some(margin) = indent.strip_prefix('-') {
                h.push(("margin-left", margin.to_owned()));
            }
            h.push(("text-indent", indent));
        }
        if let Some(value) = attr(n, "height").and_then(|s| mobi_length(&s, false)) {
            let spacer = t == "div"
                && n.children
                    .borrow()
                    .iter()
                    .all(|c| c.comment || c.name.is_none() && c.text.borrow().trim().is_empty());
            h.push((if spacer { "height" } else { "margin-top" }, value));
        }
    }
    if mobi && t == "div" && keyword(n, "data-amznpagebreak") == "always" {
        h.push(("break-before", "page".into()));
    }
    if matches!(t, "img" | "div")
        && (t == "img" || mobi)
        && let Some(v) = attr(n, "border").and_then(|s| dimension(&s, false))
    {
        h.push(("border", format!("{v} solid currentcolor")));
    }
    if t == "pre"
        && let Some(cols) = attr(n, "width")
            .and_then(|s| s.trim().parse::<u32>().ok())
            .filter(|n| *n > 0)
    {
        h.push(("width", format!("{cols}ch")));
    }
    if mobi
        && t == "span"
        && let Some(c) = attr(n, "color").and_then(|s| color(&s))
    {
        h.push(("color", c));
    }
    if t == "font" {
        if let Some(c) = attr(n, "color").and_then(|s| color(&s)) {
            h.push(("color", c));
        }
        if let Some(f) = attr(n, "face") {
            h.push(("font-family", f));
        }
    }
    if t == "hr" {
        let size = attr(n, "size").and_then(|s| dimension(&s, false));
        let c = attr(n, "color").and_then(|s| color(&s));
        if c.is_some() || attr(n, "noshade").is_some() || size.is_some() {
            let solid = c.is_some() || attr(n, "noshade").is_some();
            h.push(("border", "0".into()));
            h.push((
                "border-top",
                format!(
                    "{} {} {}",
                    size.unwrap_or("2px".into()),
                    if solid { "solid" } else { "inset" },
                    c.unwrap_or("currentcolor".into())
                ),
            ));
        }
    }
    if t == "br" {
        let c = keyword(n, "clear");
        if matches!(c.as_str(), "left" | "right" | "all" | "none" | "both") {
            h.push(("clear", if c == "all" { "both".into() } else { c }));
        }
    }
    if matches!(
        t,
        "body" | "table" | "thead" | "tbody" | "tfoot" | "tr" | "th" | "td"
    ) || mobi && matches!(t, "div" | "span")
    {
        if let Some(c) = attr(n, "bgcolor").and_then(|s| color(&s)) {
            h.push(("background-color", c));
        }
        if let Some(p) = attr(n, "background").and_then(|s| super::resources::local_path(&s, path))
        {
            h.push((
                "background-image",
                format!("url({})", serde_json::to_string(&p).unwrap()),
            ));
            resources.insert(p);
        }
    }
    if t == "body" {
        if let Some(c) = attr(n, "text").and_then(|s| color(&s)) {
            h.push(("color", c));
        }
        for (key, alias, a, b) in [
            ("marginwidth", "leftmargin", "margin-left", "margin-right"),
            ("marginheight", "topmargin", "margin-top", "margin-bottom"),
        ] {
            if let Some(v) = attr(n, key)
                .or_else(|| attr(n, alias))
                .and_then(|s| dimension(&s, false))
            {
                h.push((a, v.clone()));
                h.push((b, v));
            }
        }
    }
    if matches!(t, "ol" | "ul" | "li")
        && let Some(v) = attr(n, "type")
    {
        let kind = match v.trim() {
            "1" => "decimal",
            "a" => "lower-alpha",
            "A" => "upper-alpha",
            "i" => "lower-roman",
            "I" => "upper-roman",
            other
                if matches!(
                    other.to_ascii_lowercase().as_str(),
                    "disc" | "circle" | "square"
                ) =>
            {
                other
            }
            _ => "",
        };
        if !kind.is_empty() {
            h.push(("list-style-type", kind.to_ascii_lowercase()));
        }
    }
    if matches!(t, "ol" | "ul" | "menu" | "dir" | "dl") && attr(n, "compact").is_some() {
        h.push(("margin-top", "0".into()));
        h.push(("margin-bottom", "0".into()));
    }
    if matches!(t, "td" | "th") && attr(n, "nowrap").is_some() {
        h.push(("white-space", "nowrap".into()));
    }
    h
}

pub(super) fn font_size(
    node: &Handle,
    reader_font: f64,
    bases: &mut Option<HashMap<usize, i32>>,
) -> Option<String> {
    if tag(node) != "font" {
        return None;
    }
    let raw = attr(node, "size")?;
    let value = raw.trim();
    let number = value.parse::<i32>().ok()?;
    // 表格的转换顺序可能与正文不同，用文档顺序确定 basefont，避免被计算缓存顺序影响。
    let size = if value.starts_with(['+', '-']) {
        let map = bases.get_or_insert_with(|| {
            let mut root = node.clone();
            loop {
                let parent = root.parent.borrow().upgrade();
                if let Some(p) = parent {
                    root = p;
                } else {
                    break;
                }
            }
            let mut stack = vec![root];
            let mut map = HashMap::new();
            let mut base = 3;
            while let Some(item) = stack.pop() {
                match tag(&item) {
                    "basefont" => {
                        if let Some(v) =
                            attr(&item, "size").and_then(|s| s.trim().parse::<i32>().ok())
                        {
                            base = v.clamp(1, 7);
                        }
                    }
                    "font" if base != 3 => {
                        map.insert(item.id, base);
                    }
                    _ => {}
                }
                stack.extend(item.children.borrow().iter().rev().cloned());
            }
            map
        });
        map.get(&node.id)
            .copied()
            .unwrap_or(3)
            .saturating_add(number)
    } else {
        number
    }
    .clamp(1, 7);
    let delta = [-2., -1., 0., 1., 2., 4., 6.][(size - 1) as usize];
    Some(format!("{}rem", (reader_font + delta) / reader_font))
}
