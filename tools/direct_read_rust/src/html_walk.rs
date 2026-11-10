use super::*;

impl Builder {
    /// `<a href>` 的落点：`章节路径#锚点`（只认书内条目）。
    pub(super) fn link_of(&self, node: &Handle) -> Option<(String, bool)> {
        let href = attr(node, "href")?;
        let fragment = href.split_once('#').map_or("", |(_, fragment)| fragment);
        // 链接表按原始 href 建键；只有锚点时值就是本章路径
        let entry = self.metadata["links"][href.as_str()].as_str()?;
        let key = if fragment.is_empty() {
            entry.to_owned()
        } else {
            format!("{entry}#{fragment}")
        };
        let footnote = attr(node, "epub:type")
            .unwrap_or_default()
            .contains("noteref")
            || attr(node, "epub:type").unwrap_or_default().split_whitespace().any(|v| v == "backlink")
            || attr(node, "role")
                .unwrap_or_default()
                .contains("doc-noteref")
            || attr(node, "role").unwrap_or_default().split_whitespace().any(|v| v == "doc-backlink")
            // 很多 EPUB2 书不给 noteref 标记，只写 <a href="#filepos...">[1]</a>
            || (looks_like_note_marker(&text_of(node))
                && (!fragment.is_empty() || superscript_note_marker(node)))
            || (!fragment.is_empty() && superscript_note_marker(node));
        // 中文编号常写成“注c”；只识别短编号且带明确的脚注往返身份。
        let marker_text = text_of(node);
        let marker = note_marker_text(&marker_text);
        let footnote =
            footnote
                || (marker.trim().starts_with('注')
                    && marker.trim().chars().count() <= 6
                    && (fragment.contains("footnote")
                        || attr(node, "id").unwrap_or_default().contains("footnote")
                        || node.parent.borrow().upgrade().is_some_and(|p| {
                            attr(&p, "id").unwrap_or_default().contains("footnote")
                        })));
        Some((key, footnote))
    }

    pub(super) fn walk_all(&mut self, node: &Handle, style: Style, block: BlockStyle) {
        for (i, child) in node.children.borrow().iter().enumerate() {
            self.walk(child, style, Some((node, i)), block);
        }
    }

    pub(super) fn walk_node(
        &mut self,
        n: &Handle,
        style: Style,
        parent: Option<(&Handle, usize)>,
        block: BlockStyle,
    ) {
        if n.name.is_none() {
            if !n.comment {
                self.text(n.text.borrow().as_str(), style, Some(n), parent);
            }
            return;
        }
        let tag = tag(n);
        if tag == "style" || tag == "link" {
            // 本章的原始样式来源已经交给统一 CSS 模块，不再算“样式被忽略”
            return;
        }
        if ignored(tag) {
            return;
        }
        if tag == "table" {
            if self.engine.is_some() {
                self.computed_of(n);
            }
            self.table(n, style);
            return;
        }
        let id = attr(n, "id");
        let classes: Vec<String> = attr(n, "class")
            .map(|value| value.split_whitespace().map(str::to_owned).collect())
            .unwrap_or_default();
        let (props, block, style) = if self.engine.is_some() {
            let computed = self.computed_of(n);
            let props = computed.to_props();
            let block = self.block_from_computed(n, block, &computed);
            let style = self.style_from_computed(n, style, &computed);
            (props, block, style)
        } else {
            let props: crate::css::Props =
                (&self
                    .styles
                    .props_for(tag, id.as_deref(), &classes, &self.ancestors))
                    .into();
            let block = self.block_style(n, block, &props);
            let style = self.style(n, style, &props);
            (props, block, style)
        };
        // hr 自己的边框只用来画那条线，不参与盒子容器（否则会把外层盒子顶掉）
        // 行内盒子独立记录文字范围，不能临时替换段落盒子：离开 small/span 时
        // 段落还没 flush，原来的做法会把红底丢掉，也会干扰外层容器背景。
        let inline_box = if matches!(
            tag,
            "small"
                | "span"
                | "b"
                | "strong"
                | "i"
                | "em"
                | "a"
                | "u"
                | "s"
                | "mark"
                | "code"
                | "sup"
                | "sub"
        ) {
            props.to_box().map(|values| {
                let id = self.next_box_id;
                self.next_box_id += 1;
                (
                    self.runs.iter().map(|r| units(&r.text)).sum::<usize>(),
                    id,
                    values,
                )
            })
        } else {
            None
        };
        let previous_box = if tag == "hr" || inline_box.is_some() {
            None
        } else if let Some(values) = props.to_box() {
            // 内边距盒子只用来缩进：列表自己的缩进已经代替了书里的列表 padding，
            // 它也不该把外层彩色／边框盒子顶掉，否则引用框会被列表切成几段。
            let list_tag = matches!(tag, "ol" | "ul" | "dl" | "li");
            let padding_only = !crate::css::Props::box_is_visual(&values);
            let inherit = padding_only
                && (list_tag
                    || self
                        .box_props
                        .as_ref()
                        .map_or(false, |(outer, _)| crate::css::Props::box_is_visual(outer)));
            if inherit {
                None
            } else {
                let box_id = self.next_box_id;
                self.next_box_id += 1;
                Some(self.box_props.replace((values, box_id)))
            }
        } else {
            None
        };
        // pre 自己的框不能顶掉外层引用框；两份样式分别登记，正文不变。
        let previous_code_parent = self.code_parent_box.clone();
        if tag == "pre" {
            self.code_parent_box = if previous_box.is_some() {
                self.quote_box
                    .clone()
                    .or_else(|| previous_box.as_ref().and_then(|outer| outer.clone()))
            } else {
                None
            };
        }
        self.ancestors.push(crate::styles::Key {
            tag: tag.to_owned(),
            id,
            classes,
        });
        self.walk_element(n, style, parent, block, &props);
        if let Some((start, id, values)) = inline_box {
            let end = self.runs.iter().map(|r| units(&r.text)).sum::<usize>();
            if end > start {
                self.pending_inline_boxes.push(PendingInlineBox {
                    start,
                    end,
                    id,
                    values,
                    scale: style.size,
                });
            }
        }
        self.ancestors.pop();
        self.code_parent_box = previous_code_parent;
        if let Some(previous) = previous_box {
            self.box_props = previous;
        }
    }

    pub(super) fn walk_element(
        &mut self,
        n: &Handle,
        style: Style,
        _parent: Option<(&Handle, usize)>,
        block: BlockStyle,
        props: &crate::css::Props,
    ) {
        let tag = tag(n);
        match tag {
            "br" => {
                self.line_break(style);
                return;
            }
            "img" | "image" => {
                self.image(n, props);
                return;
            }
            "svg" => {
                if let Some(image) = find(n, "image") {
                    self.image(&image, props);
                }
                return;
            }
            "hr" => {
                self.flush();
                self.record("divider", 1, None);
                if !self.stats {
                    let id = self.next();
                    let mut block = json!({"id":id,"kind":"divider"});
                    // 分隔线继承外层盒子，自己的上边框当作线型
                    if let Some((values, box_id)) = &self.box_props {
                        block["box"] = json!(values);
                        block["boxId"] = json!(box_id);
                    }
                    if let Some(top) = props.borders[0].as_ref() {
                        block["ln"] = json!([top.width, top.style, top.color]);
                    }
                    self.blocks.push(block);
                    self.source.push_block(self.block_owner);
                }
                return;
            }
            _ => {}
        }
        let level = if tag.len() == 2 && tag.starts_with('h') {
            tag[1..].parse::<u32>().ok().filter(|v| (1..=6).contains(v))
        } else {
            None
        };
        if let Some(level) = level {
            self.begin("heading", Some(level), block, self.quote_depth, false, None);
            self.walk_all(n, style, block);
            self.flush();
            return;
        }
        match tag {
            // 引用块：左右缩进，嵌套时继续加深
            "blockquote" => {
                let previous_quote_box = self.quote_box.clone();
                self.quote_box = self.box_props.clone();
                self.quote_depth += 1;
                let depth = self.quote_depth;
                self.begin("quote", None, block, depth, false, None);
                self.quote_container = true;
                self.walk_all(n, style, block);
                self.flush();
                self.quote_depth -= 1;
                self.quote_box = previous_quote_box;
                return;
            }
            // 代码块：保留源码行结构与行首缩进（文字本身不变）
            "pre" => {
                self.code_depth += 1;
                self.code_line_start = true;
                self.begin("code", None, block, 0, false, None);
                self.walk_all(n, style, block);
                self.flush();
                self.code_depth -= 1;
                return;
            }
            // 图注：默认居中、字号小一档
            "figcaption" => {
                let caption = if block.align().is_none() {
                    BlockStyle {
                        center: true,
                        right: false,
                        no_indent: block.no_indent,
                    }
                } else {
                    block
                };
                self.begin("caption", None, caption, self.quote_depth, false, None);
                self.walk_all(n, style, block);
                self.flush();
                return;
            }
            "ul" | "ol" => {
                self.flush();
                self.lists.push(ListState {
                    ordered: tag == "ol",
                    next: if tag == "ol" { ordered_start(n) } else { 1 },
                    list_style: props.list_style,
                });
                self.walk_all(n, style, block);
                self.lists.pop();
                self.flush();
                return;
            }
            "li" => {
                let ordinal = match self.lists.last_mut() {
                    Some(list) if list.ordered => {
                        let value =
                            match attr(n, "value").and_then(|v| v.trim().parse::<i64>().ok()) {
                                Some(value) => {
                                    list.next = value + 1;
                                    value
                                }
                                None => {
                                    let value = list.next;
                                    list.next += 1;
                                    value
                                }
                            };
                        Some(value)
                    }
                    _ => None,
                };
                // 引用块里的列表继续往里缩进
                let nest = self.lists.len().saturating_sub(1) as u32 + self.quote_depth;
                if self.source.enabled {
                    if let Some(&id) = self.element_stack.last() {
                        let count = self.source.elements[id].parent.map(|parent| {
                            self.source.elements[parent].children.iter().filter(|&&child| {
                                self.source.elements[child].tag == "li"
                            }).count() as i64
                        }).unwrap_or(1);
                        // 只补显示资料；嵌套 p 的持久正文块号、类型及文字不变。
                        self.source.elements[id].list_ordinal = Some(ordinal.unwrap_or(count));
                    }
                }
                // 先 begin（它会 flush 上一块），再记列表标记样式：
                // flush 会清空 list_style，顺序反了样式就丢了
                self.begin("listItem", None, block, nest, ordinal.is_some(), ordinal);
                // list-style 从 ol／ul 继承到 li，li 自己写了以自己为准
                self.list_style = props
                    .list_style
                    .or_else(|| self.lists.last().and_then(|list| list.list_style));
                self.walk_all(n, style, block);
                self.flush();
                return;
            }
            // 普通段落类块；引用块里的段落沿用引用样式（每个 <p> 一段）
            "p" | "dd" | "dt" | "td" | "th" => {
                let in_quote = self.quote_depth > 0 && matches!(tag, "p" | "dd" | "dt");
                let kind = if in_quote { "quote" } else { "paragraph" };
                self.begin(kind, None, block, self.quote_depth, false, None);
                self.walk_all(n, style, block);
                self.flush();
                return;
            }
            _ => {}
        }
        if boundary(tag) {
            self.flush();
            self.walk_all(n, style, block);
            return;
        }
        let previous_link = self.link.clone();
        let previous_footnote = self.footnote;
        if tag == "a" {
            if let Some((link, footnote)) = self.link_of(n) {
                if footnote && self.target.is_none() {
                    let path = link.split('#').next().unwrap_or(link.as_str());
                    self.target = Some(path.to_owned());
                }
                self.link = Some(link);
                self.footnote = footnote;
            }
        }
        self.walk_all(n, style, block);
        self.link = previous_link;
        self.footnote = previous_footnote;
    }
}
