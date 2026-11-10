use super::*;

impl Builder {
    /// 计算一个元素的作者样式；父级结果按 DOM 父子链缓存，不重复匹配。
    pub(super) fn computed_of(&mut self, node: &Handle) -> crate::css::Computed {
        if let Some(cached) = self.computed_cache.get(&node.id) {
            return cached.clone();
        }
        let parent_node = node
            .parent
            .borrow()
            .upgrade()
            .filter(|parent| parent.name.is_some());
        let parent_computed = parent_node.as_ref().map(|parent| self.computed_of(parent));
        let parent_vars = parent_node
            .as_ref()
            .and_then(|parent| self.vars_cache.get(&parent.id).cloned())
            .unwrap_or_default();
        let (computed, vars) = self
            .engine
            .as_mut()
            .expect("只有启用统一 CSS 时才调用")
            .compute(
                &crate::css::selector::ElementRef::new(node.clone()),
                parent_computed.as_ref(),
                &parent_vars,
            );
        self.computed_cache.insert(node.id, computed.clone());
        self.vars_cache.insert(node.id, vars);
        self.element_styles.insert(node.id, computed.to_json());
        computed
    }

    pub(super) fn root_context(&mut self, body: &Handle) -> (Style, BlockStyle) {
        if self.engine.is_none() {
            return (Style::default(), BlockStyle::default());
        }
        let computed = self.computed_of(body);
        let style = self.style_from_computed(body, Style::default(), &computed);
        let block = self.block_from_computed(body, BlockStyle::default(), &computed);
        (style, block)
    }

    pub(super) fn style_from_computed(
        &mut self,
        node: &Handle,
        mut style: Style,
        computed: &crate::css::Computed,
    ) -> Style {
        let tag = tag(node);
        if let Some(factor) = computed.font_size_factor {
            style.size = factor;
        }
        if let Some(weight) = computed.font_weight {
            style.css_bold = Some(weight >= 600);
        }
        if let Some(font_style) = computed.font_style {
            let italic = font_style == "italic" || font_style == "oblique";
            style.css_italic = Some(italic);
        }
        style.color = match computed.color {
            Some(crate::css::value::Color::Argb(value)) => Some(value),
            _ => None,
        };
        if computed.font_style.is_none() {
            style.css_italic = Some(false);
        }
        if computed.font_weight.is_none() {
            style.css_bold = Some(false);
        }
        if let Some(decoration) = &computed.decoration {
            style.deco = decoration.bits();
        }
        if let Some(vertical) = &computed.vertical_align {
            style.script = match vertical.as_str() {
                "super" => 1,
                "sub" => 2,
                _ => 0,
            };
        }
        if let Some(spacing) = computed
            .letter_spacing
            .as_ref()
            .and_then(|value| value.as_ref())
            .and_then(crate::css::value::Length::to_hundredths_em)
        {
            style.letter_spacing = spacing;
        }
        if let Some(spacing) = computed
            .word_spacing
            .as_ref()
            .and_then(|value| value.as_ref())
            .and_then(crate::css::value::Length::to_hundredths_em)
        {
            style.word_spacing = spacing;
        }
        // 旧正文按语义标签以及行内 style 的粗体/斜体合并，再裁片段空白。
        // 统一 CSS 只接管实际外观，不能丢掉旧的行内声明边界；否则
        // span 内多个 b 之间的空格会被多裁一次，图片偏移和章节长度都改变。
        if let Some(css) = attr(node, "style") {
            for part in css.split(';') {
                if let Some((key, value)) = part.split_once(':') {
                    let value = value.trim().to_lowercase();
                    match key.trim().to_lowercase().as_str() {
                        "font-weight" if !value.is_empty() => {
                            style.bold = value == "bold"
                                || value == "bolder"
                                || value.parse::<i64>().is_ok_and(|v| v >= 600);
                            style.suppress_bold = !style.bold;
                        }
                        "font-style" if !value.is_empty() => {
                            style.italic = value == "italic" || value == "oblique";
                            style.suppress_italic = !style.italic;
                        }
                        _ => {}
                    }
                }
            }
        }
        if !style.suppress_bold && matches!(tag, "b" | "strong") {
            style.bold = true;
        }
        if !style.suppress_italic && matches!(tag, "i" | "em") {
            style.italic = true;
        }
        style
    }

    pub(super) fn block_from_computed(
        &mut self,
        node: &Handle,
        mut block: BlockStyle,
        computed: &crate::css::Computed,
    ) -> BlockStyle {
        if let Some(align) = computed.text_align {
            match align {
                "center" => {
                    block.center = true;
                    block.right = false;
                }
                "right" | "end" => {
                    block.center = false;
                    block.right = true;
                }
                "left" | "start" | "justify" => {
                    block.center = false;
                    block.right = false;
                }
                _ => {}
            }
        }
        if let Some(indent) = &computed.text_indent {
            block.no_indent = indent.is_zero();
        }
        if let Some(shadow) = &computed.text_shadow {
            if let Some(shadow) = shadow.first().and_then(crate::css::value::Shadow::legacy) {
                self.pending_text_shadow = Some(shadow.to_vec());
            }
        }
        if let Some(margin) = &computed.margin {
            let values = [&margin.top, &margin.right, &margin.bottom, &margin.left];
            if values.iter().any(|value| value.is_some()) {
                self.pending_margin = Some(
                    values
                        .iter()
                        .map(|value| {
                            value
                                .as_ref()
                                .and_then(crate::css::value::Length::to_hundredths_em)
                                .unwrap_or(0)
                        })
                        .collect(),
                );
            }
        }
        // 表现属性仍按 HTML 规则覆盖 CSS（旧浏览器行为）。
        if tag(node) == "center" {
            block.center = true;
            block.right = false;
        }
        if let Some(value) = attr(node, "align") {
            match value.trim().to_ascii_lowercase().as_str() {
                "center" => {
                    block.center = true;
                    block.right = false;
                }
                "right" => {
                    block.center = false;
                    block.right = true;
                }
                "left" | "justify" => {
                    block.center = false;
                    block.right = false;
                }
                _ => {}
            }
        }
        block
    }

    pub(super) fn style(
        &mut self,
        node: &Handle,
        mut s: Style,
        props: &crate::css::Props,
    ) -> Style {
        // 语义标签的默认装饰与字号（浏览器默认样式），书里的样式表与行内声明
        // 可以覆盖，所以先于 CSS 应用。
        let t = tag(node);
        match t {
            "u" | "ins" => s.deco |= 1,
            "del" | "s" | "strike" => s.deco |= 2,
            "small" => s.size = (s.size * 0.85).clamp(0.5, 2.4),
            _ => {}
        }
        // 样式表（作者样式）先应用，行内 style 覆盖。
        // 字重／斜体只影响显示，不改变 run 边界与正文长度。
        if let Some(weight) = props.weight {
            s.css_bold = Some(weight == 1);
        }
        if let Some(italic) = props.italic {
            s.css_italic = Some(italic == 1);
        }
        if let Some(color) = props.color {
            s.color = Some(color);
        }
        if let Some(size) = props.size {
            s.size = (s.size * size).clamp(0.5, 2.4);
        }
        if let Some(decoration) = props.decoration {
            s.deco = decoration as u8;
        }
        // 字距／词距是文字属性：继承到片段，按相对字号存，测量时再乘字号。
        if let Some(value) = props.letter_spacing {
            s.letter_spacing = value;
        }
        if let Some(value) = props.word_spacing {
            s.word_spacing = value;
        }
        if let Some(css) = attr(node, "style") {
            for part in css.split(';') {
                if let Some((key, value)) = part.split_once(':') {
                    let key = key.trim().to_lowercase();
                    let value = value.trim().to_lowercase();
                    if key.is_empty() || value.is_empty() {
                        continue;
                    }
                    match key.as_str() {
                        "font-weight" => {
                            s.bold = value == "bold"
                                || value == "bolder"
                                || value.parse::<i64>().is_ok_and(|v| v >= 600);
                            s.suppress_bold = !s.bold;
                        }
                        "font-style" => {
                            s.italic = value == "italic" || value == "oblique";
                            s.suppress_italic = !s.italic;
                        }
                        // 上下标是行内属性，跟文字一起进入 run
                        "vertical-align" => {
                            s.script = if value.contains("super") {
                                1
                            } else if value.contains("sub") {
                                2
                            } else {
                                0
                            };
                        }
                        "color" => {
                            if let Some(color) = crate::styles::parse_color(&value) {
                                s.color = Some(color);
                            }
                        }
                        "font-size" => {
                            if let Some(size) = crate::styles::parse_relative_size(&value) {
                                s.size = (s.size * size).clamp(0.5, 2.4);
                            }
                        }
                        "text-decoration" => {
                            if let Some(decoration) = crate::styles::parse_decoration(&value) {
                                s.deco = decoration;
                            }
                        }
                        // 行内字距／词距：与样式表同一套解析（em／px → 百分之一 em）。
                        "letter-spacing" => {
                            if let Some(spacing) = crate::styles::parse_margin_length(&value) {
                                s.letter_spacing = spacing;
                            } else if value == "normal" {
                                s.letter_spacing = 0;
                            }
                        }
                        "word-spacing" => {
                            if let Some(spacing) = crate::styles::parse_margin_length(&value) {
                                s.word_spacing = spacing;
                            } else if value == "normal" {
                                s.word_spacing = 0;
                            }
                        }
                        // 块级属性由 block_style 处理（图片的宽度在 image() 里读），
                        // 这里不算“被忽略的样式”
                        "text-align" | "text-indent" | "width" | "max-width" => {}
                        _ => self.warning(),
                    }
                }
            }
        }
        let t = tag(node);
        if !s.suppress_bold && matches!(t, "b" | "strong") {
            s.bold = true;
        }
        if !s.suppress_italic && matches!(t, "i" | "em") {
            s.italic = true;
        }
        if t == "sup" {
            s.script = 1;
        }
        if t == "sub" {
            s.script = 2;
        }
        s
    }

    /// 块级对齐与“取消首行缩进”：`<center>`、`align` 属性和行内样式向下继承。
    pub(super) fn block_style(
        &mut self,
        node: &Handle,
        mut b: BlockStyle,
        props: &crate::css::Props,
    ) -> BlockStyle {
        if let Some(align) = props.align {
            match align {
                2 => {
                    b.center = true;
                    b.right = false;
                }
                3 => {
                    b.center = false;
                    b.right = true;
                }
                1 | 4 => {
                    b.center = false;
                    b.right = false;
                }
                _ => {}
            }
        }
        if let Some(indent) = props.indent {
            b.no_indent = indent == 0;
        }
        if let Some(shadow) = &props.text_shadow {
            self.pending_text_shadow = Some(shadow.to_vec());
        }
        // 外边距只作用于紧随其后的那一块：段落的 margin 落在自己身上，
        // 容器的 margin 落在容器内第一段上（与书本常见写法一致）。
        if let Some(margins) = &props.margins {
            self.pending_margin = Some(margins.clone());
        }
        if tag(node) == "center" {
            b.center = true;
            b.right = false;
        }
        if let Some(value) = attr(node, "align") {
            match value.trim().to_lowercase().as_str() {
                "center" => {
                    b.center = true;
                    b.right = false;
                }
                "right" => {
                    b.center = false;
                    b.right = true;
                }
                "left" | "justify" => {
                    b.center = false;
                    b.right = false;
                }
                _ => {}
            }
        }
        if let Some(css) = attr(node, "style") {
            for part in css.split(';') {
                if let Some((key, value)) = part.split_once(':') {
                    let key = key.trim().to_lowercase();
                    let value = value.trim().to_lowercase();
                    if key.is_empty() || value.is_empty() {
                        continue;
                    }
                    match key.as_str() {
                        "text-align" => match value.as_str() {
                            "center" => {
                                b.center = true;
                                b.right = false;
                            }
                            "right" => {
                                b.center = false;
                                b.right = true;
                            }
                            "left" | "justify" | "start" => {
                                b.center = false;
                                b.right = false;
                            }
                            _ => {}
                        },
                        // 行内 margin：书本常见写法是 `<p style="margin:1em 0">`，
                        // 与样式表里的 margin 一样只作用于紧跟的这一块。
                        "margin" => {
                            if let Some(list) = crate::styles::parse_margin_shorthand(&value) {
                                self.pending_margin = Some(list.to_vec());
                            }
                        }
                        "margin-top" | "margin-right" | "margin-bottom" | "margin-left" => {
                            let slot = match key.as_str() {
                                "margin-top" => 0,
                                "margin-right" => 1,
                                "margin-bottom" => 2,
                                _ => 3,
                            };
                            // 先取已有的（可能来自样式表或同一段行内样式的 margin 简写）
                            let mut list = self
                                .pending_margin
                                .clone()
                                .or_else(|| props.margins.clone())
                                .unwrap_or_else(|| vec![0, 0, 0, 0]);
                            if list.len() < 4 {
                                list = vec![0, 0, 0, 0];
                            }
                            if let Some(value) = crate::styles::parse_margin_length(&value) {
                                list[slot] = value;
                                self.pending_margin = Some(list);
                            }
                        }
                        "text-indent" if zero_length(&value) => b.no_indent = true,
                        _ => {}
                    }
                }
            }
        }
        b
    }
}
