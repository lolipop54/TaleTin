// Copyright (c) 2026 GT Reader contributors. GPL-3.0-only, see LICENSE.
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
        "text-align" | "text-align-last" => {
            let alignment = match (name, value.trim().to_ascii_lowercase().as_str()) {
                ("text-align-last", "auto") => Some("auto"),
                ("text-align", "char") => Some("char"),
                ("text-align", "match-parent") => Some("match-parent"),
                _ => text_align(value),
            };
            let Some(alignment) = alignment else {
                return false;
            };
            if name == "text-align" {
                computed.text_align = Some(alignment);
            } else {
                computed.text_align_last = Some(alignment);
            }
        }
        "text-indent" => {
            let Some(length) = parse_length(value) else {
                return false;
            };
            computed.text_indent = Some(length);
        }
        "text-decoration" => {
            let Some(decoration) = parse_decoration(value) else {
                return false;
            };
            computed.decoration = Some(decoration);
        }
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
            if let Some(length) = parse_length(value).filter(|l| !matches!(l, Length::Auto)) {
                computed.vertical_align_length = Some(length);
                computed.vertical_align = None;
            } else if matches!(
                lower.as_str(),
                "super"
                    | "sub"
                    | "baseline"
                    | "middle"
                    | "top"
                    | "bottom"
                    | "legacy-center"
                    | "text-top"
                    | "text-bottom"
            ) {
                computed.vertical_align = Some(lower);
                computed.vertical_align_length = None;
            } else {
                return false;
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
        "text-emphasis-style" => {
            let value = value.trim();
            if value.len() > 2
                && ((value.starts_with('"') && value.ends_with('"'))
                    || (value.starts_with(char::from(39)) && value.ends_with(char::from(39))))
            {
                computed.emphasis = Some(value[1..value.len() - 1].to_string());
            } else {
                let raw = value.to_ascii_lowercase();
                let mut shape = None;
                let mut fill = None;
                for word in raw.split_ascii_whitespace() {
                    match word {
                        "filled" | "open" if fill.is_none() => fill = Some(word),
                        "dot" | "circle" | "double-circle" | "triangle" | "sesame"
                            if shape.is_none() =>
                        {
                            shape = Some(word)
                        }
                        "none" if raw == "none" => shape = Some(word),
                        _ => return false,
                    }
                }
                if shape.is_none() && fill.is_none() {
                    return false;
                }
                computed.emphasis = Some(
                    match (shape.unwrap_or("circle"), fill == Some("open")) {
                        ("none", _) => "",
                        ("dot", false) => "•",
                        ("dot", true) => "◦",
                        ("circle", false) => "●",
                        ("circle", true) => "○",
                        ("double-circle", false) => "◉",
                        ("double-circle", true) => "◎",
                        ("triangle", false) => "▲",
                        ("triangle", true) => "△",
                        ("sesame", false) => "﹅",
                        _ => "﹆",
                    }
                    .into(),
                );
            }
        }
        "text-emphasis-position" => {
            let words = value
                .split_ascii_whitespace()
                .map(str::to_ascii_lowercase)
                .collect::<Vec<_>>();
            if words.is_empty()
                || words.len() > 2
                || words
                    .iter()
                    .any(|s| !matches!(s.as_str(), "under" | "over" | "right" | "left"))
                || words
                    .iter()
                    .filter(|s| matches!(s.as_str(), "over" | "under"))
                    .count()
                    != 1
            {
                return false;
            }
            computed.emphasis_position = Some(words.join(" "));
        }
        "text-emphasis-color" => {
            let Some(c) = parse_color(value) else {
                return false;
            };
            computed.emphasis_color = Some(c);
        }
        "hyphens" => {
            let Some(mode) = keyword(value, &["none", "manual", "auto"]) else {
                return false;
            };
            computed.hyphens = Some(mode.to_owned());
        }
        "text-size-adjust" | "overflow-wrap" | "word-break" => {
            let lower = value.trim().to_ascii_lowercase();
            let valid = match name {
                "text-size-adjust" => {
                    matches!(lower.as_str(), "none" | "auto")
                        || matches!(parse_length(&lower), Some(Length::Percent(n)) if n >= 0.0)
                }
                "word-break" => matches!(
                    lower.as_str(),
                    "normal" | "break-all" | "keep-all" | "break-word" | "auto-phrase"
                ),
                _ => matches!(lower.as_str(), "normal" | "break-word" | "anywhere"),
            };
            if !valid {
                return false;
            }
            computed.extras.insert(name.to_owned(), lower);
        }
        "background-color" => {
            let Some(color) = parse_color(value) else {
                return false;
            };
            computed
                .background
                .get_or_insert_with(Background::default)
                .color = Some(color);
        }
        "background-image" => {
            let image = url_value(value);
            let gradient = is_gradient(value).then(|| value.to_owned());
            if image.is_none() && gradient.is_none() && !value.eq_ignore_ascii_case("none") {
                return false;
            }
            let background = computed.background.get_or_insert_with(Background::default);
            background.image = image;
            background.gradient = gradient;
        }
        "background-repeat" => {
            let lower = value.trim().to_ascii_lowercase();
            let tokens: Vec<_> = lower.split_ascii_whitespace().collect();
            if tokens.is_empty()
                || !(matches!(lower.as_str(), "repeat-x" | "repeat-y")
                    || (tokens.len() <= 2
                        && tokens
                            .iter()
                            .all(|t| matches!(*t, "repeat" | "no-repeat" | "space" | "round"))))
            {
                return false;
            }
            computed
                .background
                .get_or_insert_with(Background::default)
                .repeat = Some(value.trim().to_ascii_lowercase());
        }
        "background-position" => {
            let lower = value.trim().to_ascii_lowercase();
            let tokens: Vec<_> = lower.split_ascii_whitespace().collect();
            if tokens.is_empty()
                || !(tokens.len() <= 4
                    && tokens.iter().all(|t| {
                        matches!(*t, "left" | "right" | "center" | "top" | "bottom")
                            || parse_length(t).is_some_and(|l| !matches!(l, Length::Auto))
                    }))
            {
                return false;
            }
            computed
                .background
                .get_or_insert_with(Background::default)
                .position = Some(value.trim().to_owned());
        }
        "background-attachment" => {
            let lower = value.trim().to_ascii_lowercase();
            if !matches!(lower.as_str(), "fixed" | "scroll" | "local") {
                return false;
            }
            computed
                .background
                .get_or_insert_with(Background::default)
                .attachment = Some(lower);
        }
        "background-size" => {
            let lower = value.trim().to_ascii_lowercase();
            let tokens: Vec<_> = lower.split_ascii_whitespace().collect();
            if tokens.is_empty()
                || !(matches!(lower.as_str(), "contain" | "cover")
                    || (tokens.len() <= 2
                        && tokens.iter().all(|t| {
                            *t == "auto" || parse_length(t).is_some_and(|l| l.nonnegative_length())
                        })))
            {
                return false;
            }
            computed
                .background
                .get_or_insert_with(Background::default)
                .size = Some(value.trim().to_ascii_lowercase());
        }
        "padding-top" | "padding-right" | "padding-bottom" | "padding-left" => {
            let Some(length) = parse_length(value).filter(Length::nonnegative_length) else {
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
            let Some(style) = keyword(
                value,
                &[
                    "none", "hidden", "solid", "dotted", "dashed", "double", "groove", "ridge",
                    "inset", "outset",
                ],
            ) else {
                return false;
            };
            computed.border[index].style = Some(style.to_owned());
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
            let Some(radius) = parse_corner(value) else {
                return false;
            };
            let index = match name {
                "border-top-left-radius" => 0,
                "border-top-right-radius" => 1,
                "border-bottom-right-radius" => 2,
                _ => 3,
            };
            computed.radii.get_or_insert_with(|| {
                std::array::from_fn(|_| (Length::Px(0.0), Length::Px(0.0)))
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
            let Some(mode) = display(value) else {
                return false;
            };
            computed.display = Some(mode);
        }
        "float" => {
            let Some(mode) = keyword(
                value,
                &["none", "left", "right", "inline-start", "inline-end"],
            ) else {
                return false;
            };
            computed.float = Some(mode);
        }
        "clear" => {
            let Some(mode) = keyword(
                value,
                &[
                    "none",
                    "left",
                    "right",
                    "both",
                    "inline-start",
                    "inline-end",
                ],
            ) else {
                return false;
            };
            computed.clear = Some(mode);
        }
        "position" => {
            let Some(mode) = keyword(
                value,
                &["static", "relative", "absolute", "fixed", "sticky"],
            ) else {
                return false;
            };
            computed.position = Some(mode);
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
            let keyword = value.trim().to_ascii_lowercase();
            if name == "break-inside"
                && !matches!(
                    keyword.as_str(),
                    "auto" | "avoid" | "avoid-column" | "avoid-page" | "avoid-region"
                )
            {
                return false;
            }
            if name != "break-inside"
                && !matches!(
                    keyword.as_str(),
                    "auto"
                        | "avoid"
                        | "all"
                        | "avoid-page"
                        | "page"
                        | "left"
                        | "right"
                        | "recto"
                        | "verso"
                        | "column"
                        | "avoid-column"
                        | "region"
                        | "avoid-region"
                )
            {
                return false;
            }
            let field = match name {
                "break-before" => &mut computed.break_before,
                "break-after" => &mut computed.break_after,
                _ => &mut computed.break_inside,
            };
            *field = Some(keyword);
        }
        "width" | "height" | "min-width" | "min-height" | "max-width" | "max-height" => {
            let maximum = name.starts_with("max-");
            if maximum && value.eq_ignore_ascii_case("none") {
                if name == "max-width" {
                    computed.max_width = None;
                } else {
                    computed.max_height = None;
                }
                return true;
            }
            let Some(length) = parse_length(value)
                .filter(|v| v.nonnegative_length() || (!maximum && matches!(v, Length::Auto)))
            else {
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
        "box-decoration-break" => {
            computed.decoration_break = Some(match value.trim().to_ascii_lowercase().as_str() {
                "slice" => "slice",
                "clone" => "clone",
                _ => return false,
            });
        }
        "box-sizing" => {
            computed.box_sizing = match value.to_ascii_lowercase().as_str() {
                "content-box" => Some("contentBox"),
                "border-box" => Some("borderBox"),
                _ => return false,
            }
        }
        "bleed" => {
            // 多看既有 lefttopright 的连写，也有用空格分开的写法。
            let value = value.trim().to_ascii_lowercase();
            let mut rest = value.as_str();
            let mut mask = 0;
            if rest != "none" && rest != "all" {
                while !rest.is_empty() {
                    let Some((name, bit)) = [("left", 1), ("top", 2), ("right", 4), ("bottom", 8)]
                        .into_iter()
                        .find(|(name, _)| rest.starts_with(name))
                    else {
                        return false;
                    };
                    mask |= bit;
                    rest = rest[name.len()..].trim_start();
                }
            }
            computed.bleed = Some(if value == "all" { 15 } else { mask });
        }
        "object-fit" => {
            let fit = value.trim().to_ascii_lowercase();
            if !matches!(
                fit.as_str(),
                "fill" | "contain" | "cover" | "none" | "scale-down"
            ) {
                return false;
            }
            computed.object_fit = Some(fit);
        }
        "border-collapse" | "table-layout" | "caption-side" | "empty-cells" | "direction" => {
            let keyword = value.trim().to_ascii_lowercase();
            if !matches!(
                (name, keyword.as_str()),
                ("border-collapse", "collapse" | "separate")
                    | ("table-layout", "auto" | "fixed")
                    | ("caption-side", "top" | "bottom" | "left" | "right")
                    | ("empty-cells", "show" | "hide")
                    | ("direction", "ltr" | "rtl")
            ) {
                return false;
            }
            let slot = match name {
                "border-collapse" => &mut computed.border_collapse,
                "table-layout" => &mut computed.table_layout,
                "direction" => &mut computed.direction,
                "caption-side" => &mut computed.caption_side,
                _ => &mut computed.empty_cells,
            };
            *slot = Some(value.trim().to_ascii_lowercase());
        }
        "border-spacing" => {
            let lengths: Vec<_> = value.split_ascii_whitespace().collect();
            if lengths.is_empty() || lengths.len() > 2 {
                return false;
            }
            let spacing = |s: &str| {
                parse_length(s).filter(|l| match l {
                    Length::Px(v) | Length::Pt(v) | Length::Em(v) | Length::Rem(v) => *v >= 0.0,
                    _ => false,
                })
            };
            let Some(x) = spacing(lengths[0]) else {
                return false;
            };
            let second = if lengths.len() == 2 {
                let Some(y) = spacing(lengths[1]) else {
                    return false;
                };
                Some(y)
            } else {
                None
            };
            computed.border_spacing = Some(x);
            computed.border_spacing_y = second;
        }
        "orphans" | "widows" => {
            if !value.trim().parse::<i32>().is_ok_and(|n| n > 0) {
                return false;
            }
            computed.extras.insert(name.to_owned(), value.to_owned());
        }
        "overflow" => {
            let lower = value.trim().to_ascii_lowercase();
            let axes: Vec<_> = lower.split_ascii_whitespace().collect();
            if !(1..=2).contains(&axes.len())
                || !axes.iter().all(|a| {
                    matches!(
                        *a,
                        "visible" | "hidden" | "clip" | "scroll" | "auto" | "overlay"
                    )
                })
            {
                return false;
            }
            computed.overflow = Some(lower);
        }
        "visibility" | "user-select" => {
            let allowed: &[&str] = if name == "visibility" {
                &["visible", "hidden", "collapse"]
            } else {
                &["auto", "none", "text", "all"]
            };
            let Some(mode) = keyword(value, allowed) else {
                return false;
            };
            computed.extras.insert(name.to_owned(), mode.to_owned());
        }
        "content" => {
            let lower = value.trim().to_ascii_lowercase();
            if !matches!(lower.as_str(), "normal" | "none")
                && !split_whitespace_top_level(&lower).iter().all(|t| {
                    matches!(
                        t.as_str(),
                        "open-quote" | "close-quote" | "no-open-quote" | "no-close-quote" | "/"
                    ) || t.starts_with('"')
                        || t.starts_with('\'')
                        || [
                            "attr(",
                            "url(",
                            "counter(",
                            "counters(",
                            "image-set(",
                            "linear-gradient(",
                            "leader(",
                            "target-counter(",
                        ]
                        .iter()
                        .any(|p| t.starts_with(p) && t.ends_with(')'))
                })
            {
                return false;
            }
            computed.extras.insert(name.to_owned(), value.to_owned());
        }
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

fn parse_corner(value: &str) -> Option<(Length, Length)> {
    let mut parts = value.split_ascii_whitespace();
    let x = parse_length(parts.next()?).filter(Length::nonnegative_length)?;
    let y = match parts.next() {
        None => x.clone(),
        Some(v) => parse_length(v).filter(Length::nonnegative_length)?,
    };
    parts.next().is_none().then_some((x, y))
}

// 横纵半径各自按四角展开。任一分量无效则整条简写失效。
pub(super) fn parse_radii(value: &str) -> Option<[(Length, Length); 4]> {
    let mut axes = value.split('/');
    let x = parse_four_lengths(axes.next()?)?;
    let y = match axes.next() {
        Some(v) => parse_four_lengths(v)?,
        None => x.clone(),
    };
    if axes.next().is_some() || !x.iter().chain(y.iter()).all(Length::nonnegative_length) {
        return None;
    }
    Some(std::array::from_fn(|i| (x[i].clone(), y[i].clone())))
}

fn url_value(value: &str) -> Option<String> {
    super::value::parse_url(value)
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

#[cfg(test)]
mod radius_tests {
    use super::*;

    #[test]
    fn slash_expands_each_axis_before_pairing_corners() {
        let radii = parse_radii("4px 8px / 10% 20%").unwrap();
        assert_eq!(radii[0], (Length::Px(4.0), Length::Percent(0.1)));
        assert_eq!(radii[1], (Length::Px(8.0), Length::Percent(0.2)));
        assert_eq!(radii[2], radii[0]);
        for invalid in ["1em /", "4px -1px", "1px junk", "1px / 2px / 3px"] {
            assert!(parse_radii(invalid).is_none());
        }
    }
}
