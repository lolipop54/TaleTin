//! 列不是单元格的 DOM 祖先。按行组和跨格确定起始列，再把历史属性放到该格的层叠之前。
use super::presentation::{Hints, color, dimension, keyword};
use crate::dom::{Handle, attr, tag};
use std::collections::HashMap;

pub(crate) fn columns(table: &Handle) -> Vec<Handle> {
    let mut result = Vec::new();
    let mut stack: Vec<_> = table.children.borrow().iter().rev().cloned().collect();
    while let Some(n) = stack.pop() {
        match tag(&n) {
            "colgroup" if n.children.borrow().iter().any(|c| tag(c) == "col") => {
                stack.extend(n.children.borrow().iter().rev().cloned())
            }
            "col" | "colgroup" => {
                let span = attr(&n, "span")
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(1)
                    .clamp(1, 1000);
                result.extend(std::iter::repeat_n(n, span));
            }
            _ => {}
        }
    }
    result
}

pub(crate) fn col_attr(node: &Handle, name: &str) -> Option<String> {
    attr(node, name).or_else(|| {
        node.parent
            .borrow()
            .upgrade()
            .filter(|g| tag(g) == "colgroup")
            .and_then(|g| attr(&g, name))
    })
}

fn frame_sides(v: &str) -> Option<[bool; 4]> {
    Some(match v {
        "void" => [false; 4],
        "box" | "border" => [true; 4],
        "above" => [true, false, false, false],
        "below" => [false, false, true, false],
        "hsides" => [true, false, true, false],
        "vsides" => [false, true, false, true],
        "lhs" => [false, false, false, true],
        "rhs" => [false, true, false, false],
        _ => return None,
    })
}

pub(super) fn collect(table: &Handle, out: &mut HashMap<usize, Hints>) {
    let cols = columns(table);
    let padding = attr(table, "cellpadding").and_then(|s| dimension(&s, false));
    let border = attr(table, "border").map(|s| dimension(&s, false).unwrap_or("1px".into()));
    let frame = frame_sides(&keyword(table, "frame"));
    let rules = keyword(table, "rules");
    let rules = match rules.as_str() {
        r @ ("rows" | "cols" | "all" | "none" | "groups") => Some(r),
        _ => None,
    };
    let color = attr(table, "bordercolor")
        .and_then(|s| color(&s))
        .unwrap_or("currentcolor".into());
    let names = ["border-top", "border-right", "border-bottom", "border-left"];
    let mut hints = Hints::new();
    if let Some(v) = attr(table, "cellspacing").and_then(|s| dimension(&s, false)) {
        hints.push(("border-spacing", v));
    }
    if border.is_some() || frame.is_some() {
        let sides = frame.unwrap_or([true; 4]);
        for (i, key) in names.iter().enumerate() {
            hints.push((
                *key,
                if sides[i] {
                    format!("{} solid {color}", border.as_deref().unwrap_or("1px"))
                } else {
                    "0".into()
                },
            ));
        }
    }
    if rules.is_some() {
        hints.push(("border-collapse", "collapse".into()));
    }
    if !hints.is_empty() {
        out.insert(table.id, hints);
    }
    let draw_grid = rules.is_some() || border.as_deref().is_some_and(|s| s != "0px");
    let has_col_attrs = cols.iter().any(|n| {
        ["align", "valign", "width"]
            .iter()
            .any(|k| col_attr(n, k).is_some())
    });
    if padding.is_none() && !draw_grid && !has_col_attrs {
        return;
    }
    for col in &cols {
        if tag(col) == "col"
            && attr(col, "width").is_none()
            && let Some(raw) = col_attr(col, "width")
            && !raw.trim_end().ends_with('*')
            && let Some(v) = dimension(&raw, true)
        {
            let h = out.entry(col.id).or_default();
            if h.is_empty() {
                h.push(("width", v));
            }
        }
    }
    let direct = table.children.borrow();
    let mut previous_group = false;
    for group in direct
        .iter()
        .filter(|g| matches!(tag(g), "thead" | "tbody" | "tfoot" | "tr"))
    {
        let rows: Vec<_> = if tag(group) == "tr" {
            vec![group.clone()]
        } else {
            group
                .children
                .borrow()
                .iter()
                .filter(|c| tag(c) == "tr")
                .cloned()
                .collect()
        };
        let mut occupied_until: Vec<usize> = Vec::new();
        for (ri, row) in rows.iter().enumerate() {
            let mut ci = 0;
            for cell in row
                .children
                .borrow()
                .iter()
                .filter(|c| matches!(tag(c), "th" | "td"))
            {
                while occupied_until.get(ci).is_some_and(|end| *end > ri) {
                    ci += 1;
                }
                let mut h = Hints::new();
                if let Some(p) = &padding {
                    h.push(("padding", p.clone()));
                }
                if let Some(c) = cols.get(ci) {
                    if let Some(v) = col_attr(c, "align") {
                        h.push(("text-align", v));
                    }
                    if attr(row, "valign").is_none()
                        && attr(group, "valign").is_none()
                        && let Some(v) = col_attr(c, "valign")
                    {
                        h.push(("vertical-align", v));
                    }
                }
                if draw_grid {
                    let colgroup = |n: &Handle| {
                        if tag(n) == "colgroup" {
                            Some(n.id)
                        } else {
                            n.parent.borrow().upgrade().map(|p| p.id)
                        }
                    };
                    let group_edge = ci > 0
                        && cols.get(ci).and_then(colgroup) != cols.get(ci - 1).and_then(colgroup);
                    let sides = match rules {
                        None => [true; 4],
                        Some("all") => [ri > 0 || previous_group, false, false, ci > 0],
                        Some("rows") => [ri > 0 || previous_group, false, false, false],
                        Some("cols") => [false, false, false, ci > 0],
                        Some("groups") => [ri == 0 && previous_group, false, false, group_edge],
                        _ => [false; 4],
                    };
                    for (i, draw) in sides.iter().enumerate() {
                        if *draw {
                            h.push((names[i], format!("1px solid {color}")));
                        }
                    }
                }
                if !h.is_empty() {
                    out.insert(cell.id, h);
                }
                let span = attr(cell, "colspan")
                    .and_then(|s| s.trim().parse::<usize>().ok())
                    .unwrap_or(1)
                    .clamp(1, 1000);
                let rs = attr(cell, "rowspan")
                    .and_then(|s| s.trim().parse::<usize>().ok())
                    .unwrap_or(1);
                if occupied_until.len() < ci + span {
                    occupied_until.resize(ci + span, 0);
                }
                occupied_until[ci..ci + span].fill(if rs == 0 {
                    rows.len()
                } else {
                    ri.saturating_add(rs).min(rows.len())
                });
                ci += span;
            }
        }
        previous_group |= !rows.is_empty();
    }
}
