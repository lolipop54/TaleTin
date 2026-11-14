use super::*;

impl Builder {
    pub(super) fn text(
        &mut self,
        raw: &str,
        style: Style,
        node: Option<&Handle>,
        parent: Option<(&Handle, usize)>,
    ) {
        let breaks = parent
            .and_then(|(p, i)| attr(p, &format!("data-gt-hyphens-{i}")))
            .and_then(|v| serde_json::from_str::<Vec<usize>>(&v).ok())
            .unwrap_or_default();
        let clean = if breaks.is_empty() && self.optimized {
            Cow::Borrowed(raw)
        } else if breaks.is_empty() {
            Cow::Owned(raw.to_owned())
        } else {
            Cow::Owned(String::from_utf16_lossy(
                &raw.encode_utf16()
                    .enumerate()
                    .filter(|(i, _)| !breaks.contains(i))
                    .map(|(_, v)| v)
                    .collect::<Vec<_>>(),
            ))
        };
        let normalized = collapse(&clean);
        if normalized.is_empty() || (normalized == " " && self.runs.is_empty()) {
            return;
        }
        if self.code_depth > 0 {
            self.code_text(&clean, style, node);
            return;
        }
        self.append(&normalized, style, &clean, node, &breaks);
    }

    /// 追加一段已经折叠好的文字，返回（run 序号、run 内起点、被吸收的首空格数）。
    pub(super) fn append(
        &mut self,
        normalized: &str,
        style: Style,
        raw: &str,
        node: Option<&Handle>,
        breaks: &[usize],
    ) -> (usize, usize, usize) {
        let merges = self
            .runs
            .last()
            .is_some_and(|r| same_style(&r.style, &style));
        let run = if merges {
            self.runs.len() - 1
        } else {
            self.runs.len()
        };
        let start = if merges {
            units(&self.runs.last().unwrap().text)
        } else {
            0
        };
        let mut text = normalized.to_owned();
        let mut absorbed = 0;
        if merges {
            let last = self.runs.last().unwrap();
            if last.text.ends_with(' ') && text.starts_with(' ') {
                text.remove(0);
                absorbed = 1;
            }
        }
        if self.map {
            self.pieces
                .push(json!([node.map(|n| n.id), raw, run, breaks]));
        }
        if self.source.enabled && !text.is_empty() {
            let offset = self.runs.iter().map(|r| units(&r.text)).sum::<usize>();
            // NBSP 是作者放置的留白；旧正文仍折叠，只另记显示宽度。
            if raw.contains('\u{a0}') {
                let chars: Vec<char> = raw.chars().collect();
                let mut i = 0;
                let mut position: usize = 0;
                while i < chars.len() {
                    if html_space(chars[i]) {
                        let begin = i;
                        while i < chars.len() && html_space(chars[i]) {
                            i += 1;
                        }
                        let group = &chars[begin..i];
                        if group.contains(&'\u{a0}') && group.len() > 1 && position >= absorbed {
                            self.pending_spaces
                                .push((offset + position - absorbed, group.len()));
                        }
                        position += 1;
                    } else {
                        position += chars[i].len_utf16();
                        i += 1;
                    }
                }
            }
            self.source_spans
                .push((offset, offset + units(&text), self.element_stack.clone()));
        }
        if merges {
            self.runs.last_mut().unwrap().text.push_str(&text);
        } else {
            // run 内部不带上下标／颜色／字号；它们在 flush 末尾按最终文字切分
            let mut plain = style;
            plain.script = 0;
            plain.color = None;
            plain.size = 1.0;
            plain.css_bold = None;
            plain.css_italic = None;
            plain.deco = 0;
            self.runs.push(Run {
                text: text.clone(),
                style: plain,
                link: None,
                footnote: false,
            });
        }
        if !text.is_empty() {
            self.scripts.push(StyleMark {
                run,
                offset: start,
                length: units(&text),
                script: style.script,
                color: style.color,
                size: style.size,
                css_bold: style.css_bold,
                css_italic: style.css_italic,
                deco: style.deco,
                link: self.link.clone(),
                footnote: self.footnote,
            });
        }
        (run, start, absorbed)
    }

    /// 代码块：把源码空白段拆成「换行」和「空格」，文字仍与折叠结果逐字一致。
    ///
    /// 换行与行首缩进只记在显示信息里，不进入正文文字，长度和阅读位置不变。
    pub(super) fn code_text(&mut self, raw: &str, style: Style, node: Option<&Handle>) {
        let chars: Vec<char> = raw.chars().collect();
        let mut out = String::with_capacity(raw.len());
        let mut out_units = 0usize;
        let mut pending: Vec<(usize, u32)> = vec![];
        let mut i = 0;
        while i < chars.len() {
            if html_space(chars[i]) {
                let start = i;
                let mut last_newline = None;
                while i < chars.len() && html_space(chars[i]) {
                    if chars[i] == '\n' || chars[i] == '\r' {
                        last_newline = Some(i);
                    }
                    i += 1;
                }
                out.push(' ');
                out_units += 1;
                if let Some(newline) = last_newline {
                    let mut indent = 0u32;
                    for c in &chars[newline + 1..i] {
                        indent += if *c == '\t' { 4 } else { 1 };
                    }
                    pending.push((out_units - 1, indent));
                    self.code_line_start = true;
                } else if self.code_line_start {
                    // 行首缩进被标签拆到了下一个文本节点：补到当前行的缩进上
                    let mut count = 0u32;
                    for c in &chars[start..i] {
                        count += if *c == '\t' { 4 } else { 1 };
                    }
                    if count > 0 {
                        if let Some(mark) = self.marks.last_mut() {
                            // 标签边界前后的源码空白属于同一行，必须累计。
                            // 最终正文会裁掉该空格，不能再减去一个显示缩进。
                            mark.indent += count;
                        }
                    }
                    self.code_line_start = false;
                }
            } else {
                self.code_line_start = false;
                out.push(chars[i]);
                out_units += chars[i].len_utf16();
                i += 1;
            }
        }
        if out.is_empty() || (out == " " && self.runs.is_empty()) {
            return;
        }
        let (run, start, absorbed) = self.append(&out, style, raw, node, &[]);
        for (index, indent) in pending {
            let offset = if index < absorbed {
                match start.checked_sub(1) {
                    Some(value) => value,
                    None => continue,
                }
            } else {
                start + index - absorbed
            };
            self.marks.push(Mark {
                run,
                offset,
                indent,
            });
        }
    }

    pub(super) fn flush(&mut self) {
        let kind = self.kind;
        let level = self.level.take();
        let target = self.target.take();
        let align = self.align.take();
        let no_indent = std::mem::take(&mut self.no_indent);
        let quote_container = std::mem::take(&mut self.quote_container);
        let nest = std::mem::take(&mut self.nest);
        let ordered = std::mem::take(&mut self.ordered);
        let ordinal = self.ordinal.take();
        let list_style = self.list_style.take();
        let text_shadow = self.text_shadow.take();
        let box_props = self.box_props.clone();
        let marks = std::mem::take(&mut self.marks);
        let hard_breaks = std::mem::take(&mut self.hard_breaks);
        let scripts = std::mem::take(&mut self.scripts);
        let spaces = std::mem::take(&mut self.pending_spaces);
        let pending_images = std::mem::take(&mut self.pending_images);
        let pending_inline_boxes = std::mem::take(&mut self.pending_inline_boxes);
        self.kind = "paragraph";
        // Statistics need the same style-boundary trimming and UTF-16 count,
        // but no second vector or owned copy of every trimmed run.
        if self.stats && self.optimized && pending_images.is_empty() {
            let mut length = 0;
            let mut nonempty = false;
            let heading = self.heading.is_none() && (kind == "paragraph" || kind == "heading");
            let toc_heading = kind == "heading" && self.metadata.get("anchors").is_some();
            let mut title = String::new();
            for run in &self.runs {
                let text = run.text.trim_matches(|c| c == ' ' || c == '\n');
                if text.is_empty() {
                    continue;
                }
                nonempty = true;
                length += units(text);
                if heading || toc_heading {
                    title.push_str(text);
                }
            }
            if nonempty {
                if toc_heading {
                    self.toc_headings.push(json!([title, self.length]));
                }
                if heading {
                    self.heading = Some(title);
                }
                self.record(kind, 1 + length, None);
            }
            self.runs.clear();
            self.pieces.clear();
            self.source_spans.clear();
            self.source_anchors.clear();
            return;
        }
        // 裁掉首尾空白，同时记下每个 run 头部被裁掉的字符数：
        // 硬换行位置要减掉它，才能落在最终文字上。
        let originals = std::mem::take(&mut self.runs);
        let raw_lengths: Vec<usize> = originals.iter().map(|run| units(&run.text)).collect();
        let mut trimmed: Vec<Option<(Run, usize)>> = Vec::with_capacity(originals.len());
        let mut previous_newline = false;
        // 样式边界上保留下来的 `<br>` 空格：文字上多了这个占位，但章节索引
        // 是按旧口径（裁掉尾空格）算的。块的进度权重把它减回来，正文长度
        // 才能与旧索引一致，不会出现「正文长度与章节索引不一致」。
        let mut boundary_breaks = 0usize;
        let mut keep_trailing_runs = Vec::new();
        for (run_index, run) in originals.into_iter().enumerate() {
            // `<br>` 生成的换行空格可能正好在 run 末尾（例如标题里
            // 「第2章<br/><b>……</b>」），普通裁剪会把尾空格一起去掉，
            // 最后一步“空格换换行”就找不到落点，换行消失。带换行的 run
            // 只裁头部，保留尾空格给换行用。
            let keeps_break = hard_breaks
                .iter()
                .any(|(index, offset)| *index == run_index && *offset + 1 == units(&run.text));
            if keeps_break {
                keep_trailing_runs.push(run_index);
            }
            let (text, leading) = if keeps_break {
                trim_run_keep_break(&run.text)
            } else {
                trim_run(&run.text)
            };
            if text.is_empty() {
                trimmed.push(None);
                continue;
            }
            // 只扣除实际保留下来的换行占位。段末 <b>文字</b><br> 会产生
            // 一个全空白 run，裁剪后已经消失，不能再扣一次位置权重。
            if keeps_break {
                boundary_breaks += units(&text) - units(&trim_run(&run.text).0);
            }
            let is_newline = text == "\n";
            if is_newline && previous_newline {
                trimmed.push(None);
                continue;
            }
            previous_newline = is_newline || text.ends_with('\n');
            trimmed.push(Some((
                Run {
                    text,
                    style: run.style,
                    link: run.link,
                    footnote: run.footnote,
                },
                leading,
            )));
        }
        // 原 run 序号 → 保留后的 run 序号，以及各保留 run 的头部裁剪量
        let mut kept_index: Vec<Option<usize>> = Vec::with_capacity(trimmed.len());
        let mut kept: Vec<Run> = vec![];
        let mut kept_leading: Vec<usize> = vec![];
        for item in trimmed {
            match item {
                Some((run, leading)) => {
                    kept_index.push(Some(kept.len()));
                    kept.push(run);
                    kept_leading.push(leading);
                }
                None => kept_index.push(None),
            }
        }
        let runs = kept;
        let final_length = runs.iter().map(|r| units(&r.text)).sum::<usize>();
        for (raw, count) in spaces {
            let at = block_offset(raw, &raw_lengths, &kept_index, &kept_leading, &runs);
            let end = block_offset(raw + 1, &raw_lengths, &kept_index, &kept_leading, &runs);
            if end > at {
                self.source.spaces.push([self.blocks.len(), at, count]);
            }
        }
        for (id, raw_offset) in std::mem::take(&mut self.source_anchors) {
            let offset = block_offset(raw_offset, &raw_lengths, &kept_index, &kept_leading, &runs);
            let after = offset > 0 && offset == final_length;
            self.source.set_anchor(
                id,
                self.blocks.len() + usize::from(after),
                if after { 0 } else { offset },
            );
        }
        // 只使用裁剪后仍含正文的来源链。标签之间的空白已经不在正文中，
        // 不能让这些空白把真正属于 div/p 的内容扩大归属到 body。
        let source_spans = std::mem::take(&mut self.source_spans);
        let mut common: Option<Vec<usize>> = None;
        for (start, end, elements) in source_spans {
            let start = block_offset(start, &raw_lengths, &kept_index, &kept_leading, &runs);
            let end = block_offset(end, &raw_lengths, &kept_index, &kept_leading, &runs);
            if end > start {
                if let Some(path) = &mut common {
                    let len = path
                        .iter()
                        .zip(&elements)
                        .take_while(|(a, b)| a == b)
                        .count();
                    path.truncate(len);
                } else {
                    common = Some(elements.clone());
                }
                for eid in elements {
                    self.source.add_range(eid, self.blocks.len(), start, end);
                }
            }
        }
        let owner = common
            .unwrap_or_default()
            .into_iter()
            .rev()
            .find(|id| {
                self.source.elements.get(*id).is_some_and(|e| {
                    e.tag != "code"
                        && !matches!(
                            e.role,
                            crate::display_source::ElementRole::InlineContainer
                                | crate::display_source::ElementRole::TextSpan
                        )
                })
            })
            .unwrap_or(self.block_owner);
        let mut inline_boxes = Vec::new();
        for span in pending_inline_boxes {
            let start = block_offset(span.start, &raw_lengths, &kept_index, &kept_leading, &runs);
            let end = block_offset(span.end, &raw_lengths, &kept_index, &kept_leading, &runs);
            if end > start {
                inline_boxes.push((span.id, json!({"s": start, "e": end, "id": span.id, "box": span.values, "scale": span.scale})));
            }
        }
        inline_boxes.sort_by_key(|entry| entry.0);
        let pieces = std::mem::take(&mut self.pieces);
        if runs.is_empty() {
            // 块里没有文字：图片退回独立图片块（封面、整页插图等还是原来的排法）
            for image in pending_images {
                self.record(
                    "image",
                    1,
                    image.block["resource"].as_str().map(str::to_owned),
                );
                if self.stats {
                    continue;
                }
                let mut block = image.block;
                block["id"] = json!(self.next());
                block["kind"] = json!("image");
                if let Some((values, box_id)) = image.box_props {
                    block["box"] = json!(values);
                    block["boxId"] = json!(box_id);
                }
                if image.nest > 0 {
                    block["nest"] = json!(image.nest);
                }
                self.blocks.push(block);
                self.source.push_block(image.source_element);
            }
            return;
        }
        // 行内图片：换算到块内位置，并按合并前的分块口径还原位置权重。
        let text_length: usize = runs.iter().map(|r| units(&r.text)).sum();
        let mut inline_offsets = Vec::with_capacity(pending_images.len());
        for image in &pending_images {
            inline_offsets.push(block_offset(
                image.offset,
                &raw_lengths,
                &kept_index,
                &kept_leading,
                &runs,
            ));
        }
        for (image, offset) in pending_images.iter().zip(&inline_offsets) {
            self.source
                .add_range(image.source_element, self.blocks.len(), *offset, *offset);
        }
        let has_inline = !inline_offsets.is_empty();
        let chunks = if has_inline {
            nonempty_chunks(&inline_offsets, text_length)
        } else {
            1
        };
        let weight = (if has_inline {
            text_length + chunks + inline_offsets.len()
        } else {
            text_length + 1
        })
        .saturating_sub(boundary_breaks);
        if self.heading.is_none() && (kind == "paragraph" || kind == "heading") {
            self.heading = Some(runs.iter().map(|r| r.text.as_str()).collect());
        }
        if kind == "heading" && self.metadata.get("anchors").is_some() {
            let title: String = runs.iter().map(|r| r.text.as_str()).collect();
            self.toc_headings.push(json!([title, self.length]));
        }
        self.record(kind, weight, None);
        if self.stats {
            return;
        }
        // 换行与代码缩进：换算成块内文字下标
        let mut starts = Vec::with_capacity(runs.len());
        let mut cursor = 0usize;
        for run in &runs {
            starts.push(cursor);
            cursor += units(&run.text);
        }
        // 先按切分前的 run 换算换行位置（切分只改变 run 分布，不改变文字）
        let mut breaks: Vec<usize> = vec![];
        let mut indents: Vec<u32> = vec![];
        for mark in marks {
            if kind == "code" && self.source.enabled {
                let raw = raw_lengths.iter().take(mark.run).sum::<usize>() + mark.offset + 1;
                let at = block_offset(raw, &raw_lengths, &kept_index, &kept_leading, &runs);
                if at > 0 && at < final_length {
                    self.source
                        .code_lines
                        .push([self.blocks.len(), at, mark.indent as usize]);
                }
            }
            let Some(index) = kept_index.get(mark.run).copied().flatten() else {
                continue;
            };
            if mark.offset < kept_leading[index] {
                continue;
            }
            let start = starts[index];
            let length = units(&runs[index].text);
            let position = start + mark.offset - kept_leading[index];
            if position < start || position >= start + length {
                continue;
            }
            if breaks.last() == Some(&position) {
                // 连续换行落在同一个空格上时只保留一个；缩进取较大的
                if let Some(last) = indents.last_mut() {
                    if mark.indent > *last {
                        *last = mark.indent;
                    }
                }
                continue;
            }
            breaks.push(position);
            indents.push(mark.indent);
        }
        let runs = split_inline_styles(runs, &starts, &scripts, &kept_index, &kept_leading);
        let inline: Vec<Value> = pending_images
            .into_iter()
            .zip(inline_offsets)
            .map(|(image, offset)| {
                // 行内图片用紧凑键（与 Dart 的 InlineImage.toJson 一致）；
                // 独立图片块仍保留 resource／width／height 的旧键。
                let mut value = json!({
                    "o": offset,
                    "r": image.block["resource"].clone(),
                    "w": image.block["width"].clone(),
                    "h": image.block["height"].clone(),
                });
                if let Some(width) = image.block.get("iw") {
                    value["iw"] = width.clone();
                }
                if let Some(max_width) = image.block.get("imw") {
                    value["imw"] = max_width.clone();
                }
                if let Some(alt) = image.block.get("alt") {
                    value["a"] = alt.clone();
                }
                if let Some(link) = image.block.get("noteLink") {
                    value["nl"] = link.clone();
                }
                value
            })
            .collect();
        let id = self.next();
        // 合并前的分块顺序：每个非空文字片段、每张图片各自占一个块号。
        // 多出来的块号也走一遍，后面块的 ID 与旧版保持一致。
        for _ in 1..(chunks + inline.len()) {
            self.next();
        }
        let mut block = json!({"id":id,"kind":kind,"runs":runs.iter().map(|r| {
            if r.style.bold || r.style.italic || r.style.script != 0
                || r.style.color.is_some() || r.style.size != 1.0
                || r.style.deco != 0 || r.link.is_some() || r.footnote {
                let mut run=json!({"text":r.text});
                if r.style.bold { run["bold"]=json!(true); }
                if r.style.italic { run["italic"]=json!(true); }
                if r.style.script == 1 { run["sup"]=json!(true); }
                if r.style.script == 2 { run["sub"]=json!(true); }
                if let Some(color) = r.style.color { run["c"]=json!(color); }
                if r.style.size != 1.0 { run["fs"]=json!(r.style.size); }
                // 字距／词距是块级继承属性：只写在第一块上，正文块按同一份样式排版。
                if r.style.deco & 1 != 0 { run["u"]=json!(true); }
                if r.style.deco & 2 != 0 { run["st"]=json!(true); }
                if let Some(link) = &r.link { run["lk"]=json!(link); }
                if r.footnote { run["fn"]=json!(true); }
                run
            }
            else { json!(r.text) }
        }).collect::<Vec<_>>()});
        if let Some(level) = level {
            block["level"] = json!(level);
        }
        if !inline_boxes.is_empty() {
            block["ib"] = json!(
                inline_boxes
                    .into_iter()
                    .map(|entry| entry.1)
                    .collect::<Vec<_>>()
            );
        }
        if let Some(target) = target {
            block["target"] = json!(target);
        }
        if let Some(align) = align {
            block["align"] = json!(align);
        }
        if no_indent {
            block["noIndent"] = json!(true);
        }
        if quote_container {
            block["qb"] = json!(true);
        }
        if nest > 0 {
            block["nest"] = json!(nest);
        }
        if ordered {
            block["ordered"] = json!(true);
            if let Some(ordinal) = ordinal {
                block["ordinal"] = json!(ordinal);
            }
        }
        if !breaks.is_empty() {
            block["breaks"] = json!(breaks);
        }
        if indents.iter().any(|value| *value > 0) {
            block["indents"] = json!(indents);
        }
        if let Some((values, box_id)) = box_props {
            block["box"] = json!(values);
            block["boxId"] = json!(box_id);
        }
        if kind == "code" {
            if let Some((values, id)) = &self.code_parent_box {
                block["parentBox"] = json!({"box": values, "boxId": id});
            }
        }
        if let Some(shadow) = text_shadow {
            block["tsh"] = json!(shadow);
        }
        if let Some(style) = list_style {
            block["list"] = json!(style);
        }
        if !inline.is_empty() {
            block["iim"] = json!(inline);
            block["w"] = json!(weight);
        } else if boundary_breaks > 0 {
            // 文字里保留了换行占位空格，进度权重扣回来，章节总长仍按旧索引。
            block["w"] = json!(weight);
        }
        // 字距／词距取这一块第一个片段的样式（同块内是继承来的同一份值）。
        if let Some(first) = runs.first() {
            if first.style.letter_spacing != 0 {
                block["lsp"] = json!(first.style.letter_spacing as f64 / 100.0);
            }
            if first.style.word_spacing != 0 {
                block["wsp"] = json!(first.style.word_spacing as f64 / 100.0);
            }
        }
        if let Some(margins) = self.pending_margin.take() {
            // 全零（例如 `margin: auto` 或 `margin: 0`）不写进 JSON，缓存更小。
            if margins.iter().any(|value| *value != 0) {
                block["mg"] = json!(margins);
            }
        }
        self.blocks.push(block);
        self.source.push_block(owner);
        if self.map {
            self.maps.push(json!([id, pieces, keep_trailing_runs]));
        }
    }
}
