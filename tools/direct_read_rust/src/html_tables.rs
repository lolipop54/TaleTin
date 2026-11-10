use super::*;

impl Builder {
    pub(super) fn image(&mut self, n: &Handle, props: &crate::css::Props) {
        let Some(src) = source(n) else {
            return;
        };
        let resolved = self.metadata["images"][src].clone();
        if resolved.is_null() {
            return;
        }
        let mut block = resolved;
        if let Some(alt) = attr(n, "alt") {
            block["alt"] = json!(alt);
        }
        // 图片尺寸只用于显示：书里写了 width／max-width（百分比、em、px）才生效
        let width = if self.engine.is_some() {
            props.width
        } else {
            image_size(n, "width").or(props.width)
        };
        let max_width = if self.engine.is_some() {
            props.max_width
        } else {
            image_size(n, "max-width").or(props.max_width)
        };
        if let Some(width) = width {
            block["iw"] = json!(width);
        }
        if let Some(max_width) = max_width {
            block["imw"] = json!(max_width);
        }
        // 段落中间的图片不马上拆块：先记下位置，等这一块收尾时再决定
        // 是作为行内图片并进文字，还是（块里没有文字时）退回独立图片块。
        let offset = self.runs.iter().map(|r| units(&r.text)).sum();
        self.pending_images.push(PendingImage {
            source_element: *self.element_stack.last().unwrap_or(&self.block_owner),
            offset,
            block,
            box_props: self.box_props.clone(),
            nest: self.quote_depth,
        });
    }

    pub(super) fn table(&mut self, table: &Handle, style: Style) {
        self.flush();
        // 表格可能整个包在引用块里，背景、左边框和内边距属于外层盒子。
        // 单元格自己不带盒子；Dart 排版据此把表格画进同一个引用框。
        let table_box = self.box_props.clone();
        // `<col style="width: 14%">`：原书的列宽常常不等宽，简化排版
        // 以前一律平均分栏，宽列的文字会过早换行。
        let cols = table_columns(table);
        let col_widths = if self.engine.is_some() {
            cols.iter()
                .map(|col| match self.computed_of(col).width {
                    Some(crate::css::value::Length::Percent(value)) => value,
                    Some(_) => 0.0,
                    None => attr(col, "width")
                        .and_then(|v| {
                            v.trim()
                                .strip_suffix('%')
                                .and_then(|v| v.parse::<f64>().ok())
                        })
                        .map(|v| v / 100.)
                        .unwrap_or(0.),
                })
                .collect::<Vec<_>>()
        } else {
            table_column_widths(table)
        };
        let nested_start = self.tables.len();
        let mut cells = vec![];
        let mut occupied = HashSet::new();
        let mut row: i32 = -1;
        let mut columns = 0;
        let mut rows = 0;
        for n in table.children.borrow().iter() {
            self.table_visit(
                n,
                style,
                &mut row,
                &mut columns,
                &mut rows,
                &mut cells,
                &mut occupied,
            );
        }
        self.flush();
        if !self.stats
            && cells
                .iter()
                .any(|c: &Value| !c["blocks"].as_array().unwrap().is_empty())
        {
            self.tables.truncate(nested_start);
            let mut value = json!({"cells":cells,"columns":columns,"rows":rows});
            if self.engine.is_some() && !cols.is_empty() {
                value["colnodes"] = json!(cols.iter().map(|n| n.id).collect::<Vec<_>>());
            }
            if let Some((values, box_id)) = table_box {
                value["box"] = json!(values);
                value["boxId"] = json!(box_id);
            }
            if !col_widths.is_empty() && col_widths.iter().any(|w| *w > 0.0) {
                value["colw"] = json!(col_widths);
            }
            self.tables.push(value);
            if let Some(table_id) = self.element_stack.last().copied() {
                self.source.set_table(table_id, self.tables.len() - 1);
            }
        }
    }

    pub(super) fn table_visit(
        &mut self,
        n: &Handle,
        style: Style,
        row: &mut i32,
        columns: &mut i32,
        rows: &mut i32,
        cells: &mut Vec<Value>,
        occupied: &mut HashSet<(i32, i32)>,
    ) {
        let t = tag(n);
        if self.engine.is_some() && n.name.is_some() {
            self.computed_of(n);
        }
        if t == "tr" {
            let eid = self.source.enter(
                self.element_stack.last().copied(),
                n.id,
                "tr",
                crate::display_source::ElementRole::TableRow,
            );
            self.element_stack.push(eid);
            self.owner_stack.push(self.block_owner);
            self.block_owner = eid;
            *row += 1;
            for c in n.children.borrow().iter() {
                self.table_visit(c, style, row, columns, rows, cells, occupied);
            }
            self.flush();
            self.block_owner = self.owner_stack.pop().unwrap_or(0);
            self.source.exit(eid, self.blocks.len());
            self.element_stack.pop();
        } else if t == "td" || t == "th" {
            let eid = self.source.enter(
                self.element_stack.last().copied(),
                n.id,
                t,
                crate::display_source::ElementRole::TableCell,
            );
            self.element_stack.push(eid);
            self.owner_stack.push(self.block_owner);
            self.block_owner = eid;
            if *row < 0 {
                *row = 0;
            }
            let mut column = 0;
            while occupied.contains(&(*row, column)) {
                column += 1;
            }
            let rs = attr(n, "rowspan")
                .and_then(|v| v.trim().parse::<i32>().ok())
                .unwrap_or(1)
                .clamp(1, 1000);
            let cs = attr(n, "colspan")
                .and_then(|v| v.trim().parse::<i32>().ok())
                .unwrap_or(1)
                .clamp(1, 1000);
            self.flush();
            let first = self.blocks.len();
            // td/th 已经登记来源节点；只走内容处理，避免再创建一个同名父节点。
            self.walk_node(n, style, None, BlockStyle::default());
            self.flush();
            if !self.stats {
                cells.push(json!({"blocks":self.blocks[first..].iter().map(|b|b["id"].clone()).collect::<Vec<_>>(),"row":*row,"column":column,"rowSpan":rs,"columnSpan":cs,"header":t=="th"}));
                for r in *row..*row + rs {
                    for c in column..column + cs {
                        occupied.insert((r, c));
                    }
                }
                *columns = (*columns).max(column + cs);
                *rows = (*rows).max(*row + rs);
            }
            self.block_owner = self.owner_stack.pop().unwrap_or(0);
            self.source.exit(eid, self.blocks.len());
            self.element_stack.pop();
        } else if matches!(t, "thead" | "tbody" | "tfoot" | "colgroup" | "col") {
            let role = if matches!(t, "thead" | "tbody" | "tfoot") {
                crate::display_source::ElementRole::BlockContainer
            } else {
                crate::display_source::ElementRole::InlineContainer
            };
            let eid = self
                .source
                .enter(self.element_stack.last().copied(), n.id, t, role);
            self.element_stack.push(eid);
            for c in n.children.borrow().iter() {
                self.table_visit(c, style, row, columns, rows, cells, occupied);
            }
            self.source.exit(eid, self.blocks.len());
            self.element_stack.pop();
        } else {
            self.walk(n, style, None, BlockStyle::default());
        }
    }
}

fn table_column_widths(table: &Handle) -> Vec<f64> {
    fn percent(raw: &str) -> Option<f64> {
        let text = raw.trim();
        let value = text.strip_suffix('%')?.trim().parse::<f64>().ok()?;
        value
            .is_finite()
            .then_some((value / 100.0).clamp(0.01, 1.0))
    }
    fn style_percent(raw: &str) -> Option<f64> {
        for part in raw.split(';') {
            let Some((key, value)) = part.split_once(':') else {
                continue;
            };
            if key.trim().eq_ignore_ascii_case("width") {
                if let Some(value) = percent(value) {
                    return Some(value);
                }
            }
        }
        None
    }
    fn collect(node: &Handle, out: &mut Vec<f64>) {
        let name = tag(node);
        if name == "col" {
            let width = attr(node, "style")
                .and_then(|value| style_percent(&value))
                .or_else(|| attr(node, "width").and_then(|value| percent(&value)));
            let span = attr(node, "span")
                .and_then(|value| value.trim().parse::<usize>().ok())
                .unwrap_or(1)
                .clamp(1, 100);
            for _ in 0..span {
                out.push(width.unwrap_or(0.0));
            }
        } else if name == "colgroup" {
            for child in node.children.borrow().iter() {
                collect(child, out);
            }
        }
    }
    let mut widths = Vec::new();
    for child in table.children.borrow().iter() {
        collect(child, &mut widths);
    }
    widths
}

fn table_columns(table: &Handle) -> Vec<Handle> {
    let mut result = vec![];
    let mut stack: Vec<_> = table.children.borrow().iter().rev().cloned().collect();
    while let Some(node) = stack.pop() {
        if tag(&node) == "col" {
            let span = attr(&node, "span")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(1)
                .clamp(1, 100);
            result.extend(std::iter::repeat_n(node, span));
        } else if tag(&node) == "colgroup" {
            stack.extend(node.children.borrow().iter().rev().cloned());
        }
    }
    result
}
