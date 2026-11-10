// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 显示来源索引：在原始 DOM 还在的时候，把元素的父子、顺序、块范围和表格结构
//! 记成一份纯数据，供 Dart 在排版时构建显示树。
//!
//! 它不是新的持久正文，也不复制文字：元素只引用既有 `blockId`；表格只引用既有
//! 单元格块。索引编号只在当前源摘要和规则版本内有效，不能拿去当书签坐标。
//!
//! 元素引用最终正文 UTF-16 范围；计算样式编号在转换收尾时统一登记。

use serde_json::{Value, json};

/// 元素在显示树里的角色。语义标签和 CSS 的 `display` 不是一回事：
/// 例如 `<p>` 的语义是段落，真实 display 可以由书里改写；两者都保留。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ElementRole {
    Root,
    BlockContainer,
    Paragraph,
    Heading,
    List,
    ListItem,
    Code,
    Caption,
    InlineContainer,
    TextSpan,
    Image,
    Divider,
    Table,
    TableRow,
    TableCell,
}

impl ElementRole {
    fn code(self) -> &'static str {
        match self {
            ElementRole::Root => "root",
            ElementRole::BlockContainer => "block",
            ElementRole::Paragraph => "paragraph",
            ElementRole::Heading => "heading",
            ElementRole::List => "list",
            ElementRole::ListItem => "listItem",
            ElementRole::Code => "code",
            ElementRole::Caption => "caption",
            ElementRole::InlineContainer => "inline",
            ElementRole::TextSpan => "span",
            ElementRole::Image => "image",
            ElementRole::Divider => "divider",
            ElementRole::Table => "table",
            ElementRole::TableRow => "row",
            ElementRole::TableCell => "cell",
        }
    }
}

#[derive(Debug)]
pub struct SourceElement {
    pub id: usize,
    pub parent: Option<usize>,
    /// 原 DOM 节点编号；只在本章转换内有效，用来把计算样式挂到元素上。
    pub node_id: usize,
    pub tag: String,
    pub anchor: usize,
    pub anchor_offset: usize,
    pub ranges: Vec<[usize; 3]>,
    pub role: ElementRole,
    /// 章内第一个和最后一个正文块序号（含）；没有块时为 None。
    pub first_block: Option<usize>,
    pub last_block: Option<usize>,
    pub children: Vec<usize>,
    /// 该元素计算样式的编号；统一 CSS 接入后填写。
    pub style: Option<u32>,
    /// 表格元素对应的 `ContentTable` 序号；只有 table 有。
    pub table: Option<usize>,
    pub math: Option<String>,
    pub is_link: bool,
    /// 列表项内再套段落时，显示副本仍需使用 li 的真实编号。
    pub list_ordinal: Option<i64>,
}

#[derive(Debug)]
pub struct DisplaySource {
    pub enabled: bool,
    pub elements: Vec<SourceElement>,
    /// 每个正文块（按块顺序）由哪个元素产生。
    pub blocks: Vec<usize>,
    /// 正文块序号 → 对应 HTML 元素；表格单元格用它恢复原行列。
    pub block_elements: Vec<usize>,
    /// 代码源码换行的最终正文边界；不向旧正文插入字符。
    pub code_lines: Vec<[usize; 3]>,
    pub spaces: Vec<[usize; 3]>,
}

impl DisplaySource {
    pub fn new(enabled: bool) -> Self {
        Self {
            enabled,
            elements: vec![SourceElement {
                id: 0,
                parent: None,
                node_id: 0,
                tag: "body".to_owned(),
                anchor: 0,
                anchor_offset: 0,
                ranges: vec![],
                role: ElementRole::Root,
                first_block: None,
                last_block: None,
                children: vec![],
                style: None,
                table: None,
                math: None,
                is_link: false,
                list_ordinal: None,
            }],
            blocks: vec![],
            block_elements: vec![],
            code_lines: vec![],
            spaces: vec![],
        }
    }

    pub fn enter(
        &mut self,
        parent: Option<usize>,
        node_id: usize,
        tag: &str,
        role: ElementRole,
    ) -> usize {
        if !self.enabled {
            return 0;
        }
        let id = self.elements.len();
        self.elements.push(SourceElement {
            id,
            parent,
            node_id,
            tag: tag.to_owned(),
            anchor: self.blocks.len(),
            anchor_offset: 0,
            ranges: vec![],
            role,
            first_block: None,
            last_block: None,
            children: vec![],
            style: None,
            table: None,
            math: None,
            is_link: false,
            list_ordinal: None,
        });
        if let Some(parent) = parent {
            if let Some(parent) = self.elements.get_mut(parent) {
                parent.children.push(id);
            }
        }
        id
    }

    /// 记录元素覆盖的块范围。调用方在元素结束时用当前块数调用。
    pub fn exit(&mut self, id: usize, next_block: usize) {
        if !self.enabled {
            return;
        }
        let Some(element) = self.elements.get_mut(id) else {
            return;
        };
        // 真正覆盖的范围由 push_block/add_range 更新。离开元素时仍可能有
        // 未收尾的直接文字，不能拿“当前已输出块数”覆盖它的真实末尾。
        let _ = next_block;
    }

    pub fn set_style(&mut self, id: usize, style: u32) {
        if !self.enabled {
            return;
        }
        if let Some(element) = self.elements.get_mut(id) {
            element.style = if style == 0 { None } else { Some(style) };
        }
    }

    pub fn set_anchor(&mut self, id: usize, block: usize, offset: usize) {
        if let Some(element) = self.elements.get_mut(id) {
            element.anchor = block;
            element.anchor_offset = offset;
        }
    }

    /// 把计算样式编号按 DOM 节点挂到来源元素；body 根元素也在这里。
    pub fn apply_styles(&mut self, styles: &std::collections::HashMap<usize, u32>) {
        if !self.enabled {
            return;
        }
        for element in &mut self.elements {
            if let Some(id) = styles.get(&element.node_id) {
                element.style = if *id == 0 { None } else { Some(*id) };
            }
        }
    }

    /// 根元素对应真实 `<body>` 节点，方便挂 body 计算样式。
    pub fn set_root_node(&mut self, node_id: usize) {
        if let Some(root) = self.elements.first_mut() {
            root.node_id = node_id;
        }
    }

    pub fn set_table(&mut self, id: usize, table: usize) {
        if !self.enabled {
            return;
        }
        if let Some(element) = self.elements.get_mut(id) {
            element.table = Some(table);
        }
    }

    /// 根元素覆盖整章；它没有自己的父元素，块范围直接从 0 开始。
    pub fn finish_root(&mut self, next_block: usize) {
        if !self.enabled || next_block == 0 {
            return;
        }
        if let Some(root) = self.elements.first_mut() {
            root.first_block = Some(0);
            root.last_block = Some(next_block - 1);
        }
    }

    /// 记录一个实际输出到正文的块；`owner` 是产生它的元素。
    pub fn push_block(&mut self, owner: usize) {
        if !self.enabled {
            return;
        }
        let index = self.blocks.len();
        // 从产生块的最内层元素往上，给所有祖先补上「第一块」；
        // 这样空容器、表格单元格和引用框也能覆盖子元素的块。
        let mut current = Some(owner);
        while let Some(id) = current {
            let Some(element) = self.elements.get_mut(id) else {
                break;
            };
            if element.first_block.is_none() {
                element.first_block = Some(index);
            }
            element.last_block = Some(element.last_block.map_or(index, |v| v.max(index)));
            current = element.parent;
        }
        self.blocks.push(owner);
        self.block_elements.push(owner);
    }

    /// 文本范围只引用既有正文，行内元素也能在同一正文块内定位。
    pub fn add_range(&mut self, id: usize, block: usize, start: usize, end: usize) {
        if let Some(element) = self.elements.get_mut(id) {
            if let Some(last) = element.ranges.last_mut() {
                if last[0] == block && last[2] == start {
                    last[2] = end;
                    return;
                }
            }
            element.ranges.push([block, start, end]);
            element.first_block = Some(element.first_block.map_or(block, |v| v.min(block)));
            element.last_block = Some(element.last_block.map_or(block, |v| v.max(block)));
        }
    }

    /// 历史正文会丢弃章首的无字分隔线，显示索引必须同步减去这些块。
    /// 分隔线元素仍留下作为章首装饰，正文块号和位置权重保持旧口径。
    pub fn remove_prefix(&mut self, count: usize) {
        if count == 0 || !self.enabled {
            return;
        }
        self.blocks.drain(..count);
        self.block_elements.drain(..count);
        for e in &mut self.elements {
            e.anchor = e.anchor.saturating_sub(count);
            e.ranges.retain(|r| r[0] >= count);
            for r in &mut e.ranges {
                r[0] -= count;
            }
            if e.last_block.is_some_and(|last| last < count) {
                e.first_block = None;
                e.last_block = None;
            } else {
                e.first_block = e.first_block.map(|b| b.saturating_sub(count));
                e.last_block = e.last_block.map(|b| b.saturating_sub(count));
            }
        }
        self.code_lines.retain(|r| r[0] >= count);
        for r in &mut self.code_lines {
            r[0] -= count;
        }
        self.spaces.retain(|r| r[0] >= count);
        for r in &mut self.spaces {
            r[0] -= count;
        }
    }

    pub fn to_json(&self) -> Value {
        if !self.enabled {
            return Value::Null;
        }
        json!({
            "v": 1,
            "linkSemantics": true,
            "htmlPresentation": 3,
            "elements": self.elements.iter().map(|element| json!({
                "id": element.id,
                "p": element.parent,
                "n": element.node_id,
                "tag": element.tag,
                "link": element.is_link,
                "at": element.anchor, "off": element.anchor_offset, "ranges": element.ranges,
                "r": element.role.code(),
                "b": element.first_block,
                "e": element.last_block,
                "c": element.children,
                "s": element.style,
                "t": element.table,
                "math": element.math,
                "listOrdinal": element.list_ordinal,
            })).collect::<Vec<_>>(),
            "blocks": self.blocks,
            "blockElements": self.block_elements,
            "codeLines": self.code_lines,
            "spaces": self.spaces,
        })
    }
}

/// 标签 → 显示角色。只给「会影响块/行内/表格结构」的标签建元素，
/// 避免把每个无样式的 `<span>` 都写成一条索引。
pub fn role_of(tag: &str) -> Option<ElementRole> {
    Some(match tag {
        "body" | "html" => ElementRole::Root,
        "div" | "section" | "article" | "aside" | "header" | "footer" | "main" | "nav"
        | "figure" | "center" | "form" | "fieldset" | "details" | "summary" | "address"
        | "blockquote" => ElementRole::BlockContainer,
        "p" | "dd" | "dt" | "figcaption" => ElementRole::Paragraph,
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => ElementRole::Heading,
        "ul" | "ol" | "dl" => ElementRole::List,
        "li" => ElementRole::ListItem,
        "pre" | "code" => ElementRole::Code,
        "caption" => ElementRole::Caption,
        "span" | "b" | "strong" | "i" | "em" | "a" | "u" | "ins" | "s" | "del" | "strike"
        | "mark" | "small" | "sup" | "sub" => ElementRole::InlineContainer,
        "img" | "image" | "svg" => ElementRole::Image,
        "hr" => ElementRole::Divider,
        "table" => ElementRole::Table,
        "tr" | "thead" | "tbody" | "tfoot" => ElementRole::TableRow,
        "td" | "th" => ElementRole::TableCell,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn convert(html: &str) -> Value {
        let document = crate::html::Html::new(html.as_bytes());
        document.convert(json!({"images":{}, "links":{}, "displaySource":true}), 0)
    }

    #[test]
    fn records_nested_block_ownership() {
        let result = convert(
            r#"<body><div class="quote"><p>a</p><blockquote><p>b</p></blockquote></div></body>"#,
        );
        let source = &result["displaySource"];
        assert_eq!(source["v"], 1);
        let elements = source["elements"].as_array().unwrap();
        // body + div + p + blockquote + p
        assert_eq!(elements.len(), 5);
        // 每个正文块都能追到元素
        assert_eq!(source["blocks"].as_array().unwrap().len(), 2);
        // 外层 div 覆盖它内部的两个块
        let div = elements
            .iter()
            .find(|e| e["tag"] == "div")
            .expect("div element");
        assert_eq!(div["b"], 0);
        assert_eq!(div["e"], 1);
        let quote = elements
            .iter()
            .find(|e| e["tag"] == "blockquote")
            .expect("blockquote element");
        assert_eq!(quote["b"], 1);
        assert_eq!(quote["e"], 1);
    }

    #[test]
    fn table_cells_keep_their_blocks() {
        let result =
            convert(r#"<body><table><tr><td><p>a</p></td><td><p>b</p></td></tr></table></body>"#);
        let source = &result["displaySource"];
        let table = &source["elements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["tag"] == "table")
            .unwrap();
        assert!(table["t"].as_u64().is_some());
        assert_eq!(source["blocks"].as_array().unwrap().len(), 2);
    }
}
