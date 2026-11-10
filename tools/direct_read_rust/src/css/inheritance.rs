// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use super::style::Computed;
use super::value::*;
use crate::style_tables_generated::STYLE_PROPERTIES;
// 从生成的属性表取得继承清单，层叠关键字与默认继承共用，避免漏传表格等属性。
pub(super) static INHERITED: std::sync::LazyLock<Vec<&'static str>> =
    std::sync::LazyLock::new(|| {
        STYLE_PROPERTIES
            .iter()
            .filter(|p| p.inherited)
            .map(|p| p.name)
            .collect()
    });

pub(super) fn inherit_missing(
    computed: &mut Computed,
    parent: Option<&Computed>,
    _parent_size: f64,
) {
    let Some(parent) = parent else {
        return;
    };
    for name in INHERITED.iter() {
        copy_property(computed, Some(parent), name);
    }
    // 这两项是现有行内显示的后代传播，不属于普通CSS继承。
    // 显式initial/unset仍由层叠阶段按属性表处理，不把传播误作继承。
    computed.decoration = parent.decoration.clone();
    computed.vertical_align = parent.vertical_align.clone();
}

pub(super) fn resolve_current_color(computed: &mut Computed, parent: Option<&Computed>) {
    let current = match &computed.color {
        Some(Color::Argb(value)) => Some(*value),
        Some(Color::Current) => parent.and_then(|parent| match parent.color {
            Some(Color::Argb(value)) => Some(value),
            _ => None,
        }),
        None => None,
    };
    if matches!(computed.color, Some(Color::Current)) {
        computed.color = current.map(Color::Argb);
    }
    let resolve = |color: &mut Option<Color>| {
        if matches!(color, Some(Color::Current)) {
            *color = current.map(Color::Argb);
        }
    };
    if let Some(background) = &mut computed.background {
        resolve(&mut background.color);
    }
    for side in &mut computed.border {
        resolve(&mut side.color);
    }
    if let Some(decoration) = &mut computed.decoration {
        resolve(&mut decoration.color);
    }
    if let Some(shadows) = &mut computed.text_shadow {
        for shadow in shadows {
            resolve(&mut shadow.color);
        }
    }
    if let Some(shadows) = &mut computed.box_shadow {
        for shadow in shadows {
            resolve(&mut shadow.color);
        }
    }
}

/// CSS-wide 关键字按字段复制，避免通过字符串重新解析而丢掉单位和继承值。
pub(super) fn copy_property(out: &mut Computed, parent: Option<&Computed>, name: &str) {
    let empty = Computed::default();
    let src = parent.unwrap_or(&empty);
    if name == "font-size" {
        out.font_size = src.font_size.clone();
        out.font_size_factor = src.font_size_factor;
        return;
    }
    if name == "font-weight" {
        out.font_weight = src.font_weight;
        out.font_weight_relative = src.font_weight_relative;
        return;
    }
    macro_rules! copy { ($($key:literal => $field:ident),* $(,)?) => {
        match name { $($key => {out.$field=src.$field.clone(); return;}),* _=>{} }
    }; }
    copy! {
        "color"=>color,"font-size"=>font_size,"font-weight"=>font_weight,
        "font-style"=>font_style,"font-family"=>font_family,"line-height"=>line_height,
        "text-align"=>text_align,"text-align-last"=>text_align_last,"text-indent"=>text_indent,
        "text-decoration"=>decoration,"text-shadow"=>text_shadow,"letter-spacing"=>letter_spacing,
        "word-spacing"=>word_spacing,"white-space"=>white_space,"vertical-align"=>vertical_align,
        "text-transform"=>text_transform,"hyphens"=>hyphens,"list-style-type"=>list_style_type,
        "list-style-position"=>list_style_position,"display"=>display,"width"=>width,"height"=>height,
        "min-width"=>min_width,"min-height"=>min_height,"max-width"=>max_width,"max-height"=>max_height,
        "box-sizing"=>box_sizing,"object-fit"=>object_fit,"overflow"=>overflow,"float"=>float,
        "clear"=>clear,"position"=>position,"break-before"=>break_before,"break-after"=>break_after,
        "break-inside"=>break_inside,"border-radius"=>radii,"box-shadow"=>box_shadow,
        "border-collapse"=>border_collapse,"border-spacing"=>border_spacing,"table-layout"=>table_layout,
        "caption-side"=>caption_side,"empty-cells"=>empty_cells,
    }
    if name.ends_with("-radius") && name != "border-radius" {
        let i = match name {
            "border-top-left-radius" => 0,
            "border-top-right-radius" => 1,
            "border-bottom-right-radius" => 2,
            _ => 3,
        };
        let values = out.radii.get_or_insert_with(|| {
            [
                Length::Px(0.0),
                Length::Px(0.0),
                Length::Px(0.0),
                Length::Px(0.0),
            ]
        });
        values[i] = src
            .radii
            .as_ref()
            .map(|v| v[i].clone())
            .unwrap_or(Length::Px(0.0));
    } else if name.starts_with("padding-")
        || name.starts_with("margin-")
        || matches!(name, "top" | "right" | "bottom" | "left")
    {
        let (target, source) = if name.starts_with("padding-") {
            (&mut out.padding, &src.padding)
        } else if name.starts_with("margin-") {
            (&mut out.margin, &src.margin)
        } else {
            (&mut out.inset, &src.inset)
        };
        let edges = target.get_or_insert_with(|| Edges {
            top: None,
            right: None,
            bottom: None,
            left: None,
        });
        let empty = Edges {
            top: None,
            right: None,
            bottom: None,
            left: None,
        };
        let source = source.as_ref().unwrap_or(&empty);
        match name.rsplit('-').next().unwrap_or("") {
            "top" => edges.top = source.top.clone(),
            "right" => edges.right = source.right.clone(),
            "bottom" => edges.bottom = source.bottom.clone(),
            "left" => edges.left = source.left.clone(),
            _ => {}
        }
    } else if name.starts_with("border-") {
        let side = if name.starts_with("border-top") {
            0
        } else if name.starts_with("border-right") {
            1
        } else if name.starts_with("border-bottom") {
            2
        } else {
            3
        };
        match name.rsplit('-').next().unwrap_or("") {
            "width" => out.border[side].width = src.border[side].width.clone(),
            "style" => out.border[side].style = src.border[side].style.clone(),
            "color" => out.border[side].color = src.border[side].color.clone(),
            _ => {}
        }
    } else if name.starts_with("background-") {
        let target = out.background.get_or_insert_with(|| Background {
            color: None,
            image: None,
            repeat: None,
            position: None,
            size: None,
            raw: None,
        });
        let empty = Background {
            color: None,
            image: None,
            repeat: None,
            position: None,
            size: None,
            raw: None,
        };
        let src = src.background.as_ref().unwrap_or(&empty);
        match name {
            "background-color" => target.color = src.color.clone(),
            "background-image" => target.image = src.image.clone(),
            "background-repeat" => target.repeat = src.repeat.clone(),
            "background-position" => target.position = src.position.clone(),
            "background-size" => target.size = src.size.clone(),
            _ => {}
        }
    }
}
pub(super) fn reset_property(out: &mut Computed, name: &str) {
    copy_property(out, None, name);
    if name == "font-size" {
        out.font_size_factor = Some(1.0);
    }
    if name == "font-weight" {
        out.font_weight_relative = None;
    }
}

#[cfg(test)]
mod tests {
    use super::super::properties::parse_property;
    use super::*;

    #[test]
    fn registered_inherited_values_survive_default_inheritance() {
        let values = [
            ("color", "red"),
            ("font-size", "1.5em"),
            ("font-weight", "700"),
            ("font-style", "italic"),
            ("font-family", "serif"),
            ("line-height", "1.6"),
            ("text-align", "right"),
            ("text-align-last", "center"),
            ("text-indent", "2em"),
            ("text-shadow", "1px 2px 3px blue"),
            ("letter-spacing", "2px"),
            ("word-spacing", "3px"),
            ("text-transform", "uppercase"),
            ("white-space", "pre"),
            ("hyphens", "manual"),
            ("list-style-type", "square"),
            ("list-style-position", "inside"),
            ("border-collapse", "collapse"),
            ("border-spacing", "2px"),
            ("caption-side", "bottom"),
            ("empty-cells", "hide"),
        ];
        for (name, value) in values {
            assert!(
                STYLE_PROPERTIES
                    .iter()
                    .any(|p| p.name == name && p.inherited)
            );
            let mut parent = Computed::default();
            assert!(
                parse_property(&mut parent, name, value, None, 1.0),
                "{name}"
            );
            let mut child = Computed::default();
            inherit_missing(&mut child, Some(&parent), 1.0);
            assert_eq!(child.to_json(), parent.to_json(), "{name}");
        }
    }
}
