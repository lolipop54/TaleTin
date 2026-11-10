// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
// Conversion mirrors the reader's existing block/run rules, including separate
// trimming at style boundaries. UTF-16 lengths are used for all reader positions.
use crate::display_source::{DisplaySource, role_of};
use crate::dom::{Dom, Handle, attr, tag};
use html5ever::{parse_document, tendril::TendrilSink};
use serde_json::{Value, json};
use std::borrow::Cow;
use std::collections::HashSet;
pub struct Html {
    pub output: Vec<u8>,
    dom: Dom,
    optimized: bool,
}
// All Rc nodes belong exclusively to this tree; none escape the native API.
// Moving the entire owner between workers never shares an Rc or a RefCell.
unsafe impl Send for Html {}
fn ignored(tag: &str) -> bool {
    matches!(
        tag,
        "script"
            | "noscript"
            | "iframe"
            | "object"
            | "embed"
            | "audio"
            | "video"
            | "canvas"
            | "map"
            | "area"
            | "source"
            | "track"
            | "template"
            | "meta"
            | "base"
            | "param"
            | "input"
            | "button"
            | "select"
            | "option"
            | "textarea"
    )
}
fn boundary(tag: &str) -> bool {
    matches!(
        tag,
        "div"
            | "section"
            | "article"
            | "aside"
            | "header"
            | "footer"
            | "main"
            | "nav"
            | "figure"
            | "ul"
            | "ol"
            | "dl"
            | "table"
            | "tr"
            | "tbody"
            | "thead"
            | "tfoot"
            | "body"
            | "html"
            | "center"
            | "form"
            | "fieldset"
            | "details"
            | "summary"
            | "address"
            | "caption"
            | "colgroup"
            | "col"
    )
}
fn source(n: &Handle) -> Option<String> {
    attr(n, "src")
        .or_else(|| attr(n, "xlink:href"))
        .or_else(|| attr(n, "href"))
}
fn find(node: &Handle, name: &str) -> Option<Handle> {
    let mut stack = vec![node.clone()];
    while let Some(n) = stack.pop() {
        if tag(&n) == name {
            return Some(n);
        }
        stack.extend(n.children.borrow().iter().rev().cloned());
    }
    None
}
#[path = "html_styles.rs"]
mod styles;
#[path = "html_tables.rs"]
mod tables;
#[path = "html_text.rs"]
mod text;
#[path = "html_text_helpers.rs"]
mod text_helpers;
#[path = "html_walk.rs"]
mod walk;

#[path = "html_style_sources.rs"]
mod style_sources;

impl Html {
    pub fn new(input: &[u8]) -> Self {
        Self::with_options(input, false)
    }
    pub fn with_options(input: &[u8], optimized: bool) -> Self {
        // Source is already decoded by the EPUB archive boundary.
        let dom = parse_document(
            if optimized {
                Dom::with_options(true)
            } else {
                Dom::new()
            },
            Default::default(),
        )
        .one(String::from_utf8_lossy(input).as_ref());
        crate::note_links::repair(&dom);
        Self {
            dom,
            optimized,
            output: Vec::new(),
        }
    }
    pub fn refs(&self) -> Value {
        let mut images = vec![];
        let mut links = vec![];
        let mut stack = find(&self.dom.document, "body")
            .map(|b| {
                b.children
                    .borrow()
                    .iter()
                    .rev()
                    .cloned()
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        while let Some(n) = stack.pop() {
            let t = tag(&n);
            if ignored(t) || t == "style" || t == "link" {
                continue;
            }
            if t == "svg" {
                if let Some(image) = find(&n, "image") {
                    if let Some(src) = source(&image) {
                        images.push(src);
                    }
                }
                continue;
            }
            if t == "img" || t == "image" {
                if let Some(src) = source(&n) {
                    images.push(src);
                }
                continue;
            }
            // 所有书内链接都要收集：脚注引用要显示气泡，普通链接要能点击跳转。
            // 书外链接由 Dart 侧解析时丢掉（resolveEntryPath 返回 null）。
            if t == "a" {
                if let Some(href) = attr(&n, "href") {
                    links.push(href);
                }
            }
            stack.extend(n.children.borrow().iter().rev().cloned());
        }
        json!({"images":images,"links":links,"css":style_sources::style_sources(&self.dom)})
    }
    fn build(&self, metadata: Value, flags: u32) -> Builder {
        let mut build = Builder::new(metadata, flags | if self.optimized { 4 } else { 0 });
        if let Some(body) = find(&self.dom.document, "body") {
            build.source.set_root_node(body.id);
            let (root_style, root_block) = build.root_context(&body);
            build.walk_all(&body, root_style, root_block);
        }
        build.flush();
        build.source.finish_root(build.blocks.len());
        let mut removed = 0;
        while !build.blocks.is_empty()
            && build.blocks[0]["kind"] != "image"
            && build.blocks[0].get("runs").is_none()
        {
            build.blocks.remove(0);
            removed += 1;
        }
        build.source.remove_prefix(removed);
        build
    }
    pub fn convert(&self, metadata: Value, flags: u32) -> Value {
        if metadata.get("styleProgram").is_some() {
            return crate::css::program::evaluate(&metadata);
        }
        let anchors = metadata.get("anchors").cloned();
        let anchor_metadata = metadata.clone();
        let mut build = self.build(metadata, flags);
        // 批次 C：块与片段各带一个样式表编号，表随正文一起输出；旧显示字段同时保留（双写）。
        let (styles, element_style_ids) =
            crate::style_table::attach_with_elements(&mut build.blocks, &build.element_styles);
        build.source.apply_styles(&element_style_ids);
        let mut source = build.source.to_json();
        if build.engine.is_some() {
            let mut declared: Vec<_> = build
                .computed_cache
                .iter()
                .filter_map(|(id, style)| style.font_size_declared.then_some(*id))
                .collect();
            declared.sort_unstable();
            source["fontSizeDeclarations"] = json!(declared);
        }
        if let Some(engine) = &build.engine {
            source["computed"] = json!(true);
            let mut resources = engine.resources();
            resources.sort();
            source["backgroundResources"] = json!(resources);
            if !engine.font_faces().is_empty() {
                source["fontFaces"] = json!(engine.font_faces());
            }
            if engine.needs_environment() {
                source["css"] = json!({"nodes":self.dom.style_nodes(),"cssSources":build.metadata["cssSources"],"cssFiles":build.metadata["cssFiles"],"documentPath":build.metadata["documentPath"],"unifiedCss":true});
            }
        }
        let mut result = json!({"blocks":build.blocks,"tables":build.tables,"heading":build.heading,"warnings":build.warnings,
            "length":build.length,"singleImage":build.single_image,"pieces":build.maps,"styles":styles});
        if !source.is_null() {
            result["displaySource"] = source;
        }
        if anchors.is_some() {
            result["tocHeadings"] = json!(build.toc_headings);
        }
        if build.map {
            result["dom"] = self.export(&self.dom.document);
        }
        if anchors
            .as_ref()
            .is_some_and(|a| a.as_array().is_some_and(|a| !a.is_empty()))
        {
            // Reuse this parsed tree. Only the small target positions leave the
            // import batch; original HTML and standard body are never saved.
            crate::original::sanitize_dom(&self.dom);
            result["tocPositions"] = self.anchor_positions(anchor_metadata);
        }
        result
    }
    pub fn anchor_positions(&self, metadata: Value) -> Value {
        let wanted = metadata["anchors"].as_array().cloned().unwrap_or_default();
        // Use the same conversion and source pieces, but keep its large DOM
        // graph native; only the requested targets and their blocks leave Rust.
        let build = self.build(metadata, 2);
        crate::html_anchors::positions(&self.dom, &build.blocks, &build.maps, &wanted)
    }
    fn export(&self, node: &Handle) -> Value {
        let attrs: serde_json::Map<String, Value> = node
            .attrs
            .borrow()
            .iter()
            .map(|a| {
                let k = a
                    .name
                    .prefix
                    .as_ref()
                    .map(|p| format!("{}:{}", p, a.name.local))
                    .unwrap_or(a.name.local.to_string());
                (k, json!(a.value.as_ref()))
            })
            .collect();
        let children = node
            .children
            .borrow()
            .iter()
            .map(|n| self.export(n))
            .collect::<Vec<_>>();
        json!([
            node.id,
            tag(node),
            node.text.borrow().as_str(),
            node.comment,
            attrs,
            children,
            node.name.as_ref().map(|n| n.ns.to_string())
        ])
    }
}
#[derive(Clone, Copy)]
struct Style {
    bold: bool,
    italic: bool,
    /// 0 正常、1 上标、2 下标
    script: u8,
    suppress_bold: bool,
    suppress_italic: bool,
    /// 书内文字颜色（ARGB）；None 跟随阅读主题
    color: Option<u32>,
    /// CSS 层叠后的相对字号倍数
    size: f64,
    /// 样式表给的字重／斜体：只影响显示，不参与 run 合并
    css_bold: Option<bool>,
    css_italic: Option<bool>,
    /// 文字装饰：0 无、1 下划线、2 删除线、3 两者都有（只影响显示）
    deco: u8,
    /// 字距／词距（相对字号的百分之一 em，可为负）；0 表示书里没写
    letter_spacing: i64,
    word_spacing: i64,
}
impl Default for Style {
    fn default() -> Self {
        Self {
            bold: false,
            italic: false,
            script: 0,
            suppress_bold: false,
            suppress_italic: false,
            color: None,
            size: 1.0,
            css_bold: None,
            css_italic: None,
            deco: 0,
            letter_spacing: 0,
            word_spacing: 0,
        }
    }
}
/// 块的显示信息（对齐与“取消首行缩进”），沿标签树向下继承。
#[derive(Clone, Copy, Default, PartialEq)]
struct BlockStyle {
    center: bool,
    right: bool,
    no_indent: bool,
}
impl BlockStyle {
    fn align(&self) -> Option<&'static str> {
        if self.center {
            Some("center")
        } else if self.right {
            Some("right")
        } else {
            None
        }
    }
}
struct Run {
    text: String,
    style: Style,
    /// 书内链接目标（`章节路径#锚点`）与是否脚注引用；只用于点击交互
    link: Option<String>,
    footnote: bool,
}
/// 待换算成块内下标的硬换行：追加时的 run 序号、run 内偏移、下一行缩进空格数。
struct Mark {
    run: usize,
    offset: usize,
    indent: u32,
}
/// 一段文字的显示样式（相对追加时的 run）。合并与裁剪仍按旧规则，最后再切分。
struct StyleMark {
    run: usize,
    offset: usize,
    length: usize,
    script: u8,
    color: Option<u32>,
    size: f64,
    css_bold: Option<bool>,
    css_italic: Option<bool>,
    /// 文字装饰：0 无、1 下划线、2 删除线、3 两者都有
    deco: u8,
    /// 书内链接目标（`章节路径#锚点`）与是否脚注引用
    link: Option<String>,
    footnote: bool,
}
struct ListState {
    ordered: bool,
    next: i64,
    /// 列表容器上的 list-style（CSS 里由 li 继承）
    list_style: Option<i32>,
}
/// 段落中间遇到、还没确定属于哪一段的行内图片。
struct PendingImage {
    source_element: usize,
    /// 遇到图片时已收集的原始文字长度（UTF-16）
    offset: usize,
    /// 图片块字段（resource／width／height／alt／iw／imw），不含 id 与 kind
    block: Value,
    /// 独立图片块沿用遇到图片时的盒子与引用层级（外层作用域可能已经退出）
    box_props: Option<(Vec<i64>, i64)>,
    nest: u32,
}
struct PendingInlineBox {
    start: usize,
    end: usize,
    id: i64,
    values: Vec<i64>,
    scale: f64,
}
struct Builder {
    metadata: Value,
    stats: bool,
    optimized: bool,
    map: bool,
    blocks: Vec<Value>,
    tables: Vec<Value>,
    runs: Vec<Run>,
    pieces: Vec<Value>,
    source_spans: Vec<(usize, usize, Vec<usize>)>,
    /// 空元素也可能夹在尚未收段的文字里；收尾时和文字使用同一个偏移换算。
    source_anchors: Vec<(usize, usize)>,
    maps: Vec<Value>,
    warnings: Vec<&'static str>,
    heading: Option<String>,
    seq: usize,
    kind: &'static str,
    level: Option<u32>,
    target: Option<String>,
    /// 当前所在的 `<a>`：`章节路径#锚点` 与是否脚注引用
    link: Option<String>,
    footnote: bool,
    length: usize,
    count: usize,
    single_image: Option<String>,
    toc_headings: Vec<Value>,
    // 块的显示信息：对齐、取消首行缩进、列表层级与编号
    align: Option<&'static str>,
    no_indent: bool,
    nest: u32,
    ordered: bool,
    ordinal: Option<i64>,
    marks: Vec<Mark>,
    /// `<br>` 产生的换行标记位置；裁剪 run 时保护这个尾空格，否则换行会被吞掉。
    hard_breaks: Vec<(usize, usize)>,
    pending_spaces: Vec<(usize, usize)>,
    scripts: Vec<StyleMark>,
    lists: Vec<ListState>,
    quote_depth: u32,
    /// 当前块是不是 `<blockquote>` 元素本身（不是引用里的段落）。
    /// 这类块的文字不补阅读器首行缩进，和原书 WebView 的默认行为一致。
    quote_container: bool,
    code_depth: u32,
    // 样式表与盒子作用域
    styles: crate::styles::BookStyles,
    ancestors: Vec<crate::styles::Key>,
    box_props: Option<(Vec<i64>, i64)>,
    next_box_id: i64,
    code_parent_box: Option<(Vec<i64>, i64)>,
    quote_box: Option<(Vec<i64>, i64)>,
    list_style: Option<i32>,
    text_shadow: Option<Vec<i64>>,
    pending_text_shadow: Option<Vec<i64>>,
    /// 当前元素的四边外边距（来自作者样式或行内样式），由紧随其后的那一块消费一次。
    pending_margin: Option<Vec<i64>>,
    /// 代码块里当前是否在行首（换行后的缩进可能被标签拆到下一个文本节点）
    code_line_start: bool,
    /// 段落中间遇到的行内图片：收块时再换算成块内位置
    pending_images: Vec<PendingImage>,
    pending_inline_boxes: Vec<PendingInlineBox>,
    /// S1 显示来源索引；开关关闭时只有空结构，不产生额外 JSON。
    source: DisplaySource,
    element_stack: Vec<usize>,
    /// 块级元素的归属栈：行内元素不改变当前块由谁产生。
    owner_stack: Vec<usize>,
    /// 当前正在生成的块由哪个元素产生（块收尾时写进来源索引）。
    block_owner: usize,
    /// 统一 CSS 引擎；元数据没有有序来源时为 None，继续走旧路径。
    engine: Option<crate::css::Engine>,
    /// 每个 DOM 节点的计算结果与自定义属性；按节点 id 缓存，父子链只算一次。
    computed_cache: std::collections::HashMap<usize, crate::css::Computed>,
    vars_cache: std::collections::HashMap<usize, std::collections::HashMap<String, String>>,
    /// 元素 id → 计算样式 JSON，最后 intern 进样式表并写进来源索引。
    element_styles: std::collections::HashMap<usize, Value>,
}
use text_helpers::*;
/// 节点里的文字（跳过脚本样式），用于判断链接是否为脚注编号。
fn text_of(node: &Handle) -> String {
    let mut out = String::new();
    let mut stack = vec![node.clone()];
    while let Some(n) = stack.pop() {
        if n.name.is_none() {
            out.push_str(&n.text.borrow());
            continue;
        }
        let name = tag(&n);
        if name == "script" || name == "style" {
            continue;
        }
        stack.extend(n.children.borrow().iter().rev().cloned());
    }
    out
}

/// `<ol start="3">` 的起始序号。
fn ordered_start(node: &Handle) -> i64 {
    attr(node, "start")
        .and_then(|v| v.trim().parse::<i64>().ok())
        .unwrap_or(1)
}

/// 图片元素自己的行内 `width`／`max-width`（`style="width:60%"`）。
fn image_size(node: &Handle, key: &str) -> Option<[i64; 2]> {
    let css = attr(node, "style")?;
    for part in css.split(';') {
        if let Some((name, value)) = part.split_once(':') {
            if name.trim().eq_ignore_ascii_case(key) {
                return crate::styles::parse_size(value);
            }
        }
    }
    None
}
/// 0、0px、0em、0% 等零长度写法（与 Dart 侧正则口径一致）。
fn zero_length(value: &str) -> bool {
    let mut chars = value.trim().chars().peekable();
    if chars.peek() == Some(&'+') {
        chars.next();
    }
    let mut zeros = 0;
    while chars.peek() == Some(&'0') {
        chars.next();
        zeros += 1;
    }
    if chars.peek() == Some(&'.') {
        chars.next();
        let mut fraction = 0;
        while chars.peek() == Some(&'0') {
            chars.next();
            fraction += 1;
        }
        if fraction == 0 && zeros == 0 {
            return false;
        }
        zeros += fraction;
    }
    if zeros == 0 {
        return false;
    }
    chars.all(|c| c.is_ascii_alphabetic() || c == '%')
}
pub(crate) fn html_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n'
            | '\u{b}'
            | '\u{c}'
            | '\r'
            | ' '
            | '\u{a0}'
            | '\u{1680}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
            | '\u{feff}'
    ) || ('\u{2000}'..='\u{200a}').contains(&c)
}
pub(crate) fn collapse(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut space = false;
    for c in raw.chars() {
        if html_space(c) {
            if !space {
                out.push(' ');
            }
            space = true;
        } else {
            out.push(c);
            space = false;
        }
    }
    out
}
/// 表格列宽（百分比）：`<colgroup><col style="width: 14%">…`。
///
/// 返回每列的相对宽度；没有写宽度的列记 0，由 Dart 按剩余宽度平均补。
/// 只认百分比，px／em 混排时按未声明处理，退回平均列宽。
impl Builder {
    fn new(metadata: Value, flags: u32) -> Self {
        let metadata_styles = metadata.get("styles").cloned().unwrap_or(Value::Null);
        let source_enabled = flags & 8 != 0
            || metadata
                .get("displaySource")
                .and_then(Value::as_bool)
                .unwrap_or(false);
        let engine = crate::css::Engine::from_metadata(&metadata);
        Self {
            metadata,
            stats: flags & 1 != 0,
            optimized: flags & 4 != 0,
            map: flags & 2 != 0,
            blocks: vec![],
            tables: vec![],
            runs: vec![],
            pieces: vec![],
            source_spans: vec![],
            source_anchors: vec![],
            maps: vec![],
            warnings: vec![],
            heading: None,
            seq: 0,
            kind: "paragraph",
            level: None,
            target: None,
            link: None,
            footnote: false,
            length: 0,
            count: 0,
            single_image: None,
            toc_headings: vec![],
            align: None,
            no_indent: false,
            nest: 0,
            ordered: false,
            ordinal: None,
            marks: vec![],
            hard_breaks: vec![],
            pending_spaces: vec![],
            scripts: vec![],
            lists: vec![],
            quote_depth: 0,
            quote_container: false,
            code_depth: 0,
            styles: crate::styles::BookStyles::from_json(&metadata_styles),
            ancestors: vec![],
            box_props: None,
            next_box_id: 1,
            code_parent_box: None,
            quote_box: None,
            list_style: None,
            text_shadow: None,
            pending_text_shadow: None,
            pending_margin: None,
            code_line_start: false,
            pending_images: vec![],
            pending_inline_boxes: vec![],
            source: DisplaySource::new(source_enabled),
            element_stack: vec![0],
            owner_stack: vec![0],
            block_owner: 0,
            engine,
            computed_cache: std::collections::HashMap::new(),
            vars_cache: std::collections::HashMap::new(),
            element_styles: std::collections::HashMap::new(),
        }
    }

    fn warning(&mut self) {
        if self.warnings.is_empty() {
            self.warnings.push("部分排版样式已忽略");
        }
    }

    fn next(&mut self) -> String {
        self.seq += 1;
        format!("b{}", self.seq)
    }

    fn record(&mut self, kind: &str, length: usize, image: Option<String>) {
        if self.count == 0 && kind != "image" && length == 1 {
            return;
        }
        self.count += 1;
        self.length += length;
        self.single_image = if self.count == 1 && kind == "image" {
            image
        } else {
            None
        };
    }

    fn walk(
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
        let tag_name = tag(n);
        if tag_name == "style" || tag_name == "link" || ignored(tag_name) {
            return;
        }
        // 保留每个真实元素；未知标签按行内容器处理，其 display 仍可由 CSS 改写。
        let eid = match Some(
            role_of(tag_name).unwrap_or(crate::display_source::ElementRole::InlineContainer),
        ) {
            Some(role) => {
                let id =
                    self.source
                        .enter(self.element_stack.last().copied(), n.id, tag_name, role);
                self.element_stack.push(id);
                if self.source.enabled {
                    self.source_anchors
                        .push((id, self.runs.iter().map(|r| units(&r.text)).sum()));
                }
                id
            }
            None => 0,
        };
        if tag_name == "math" && self.source.enabled {
            self.source.elements[eid].math = Some(crate::mathml::serialize(n));
        }
        if self.source.enabled && tag_name == "a" && attr(n, "href").is_some() {
            // 来源链接身份不依赖地址是否能解析；未知设备协议也不能变成普通正文缩进。
            self.source.elements[eid].is_link = true;
        }
        let block_level = eid != 0
            && matches!(
                role_of(tag_name),
                Some(
                    crate::display_source::ElementRole::BlockContainer
                        | crate::display_source::ElementRole::Paragraph
                        | crate::display_source::ElementRole::Heading
                        | crate::display_source::ElementRole::List
                        | crate::display_source::ElementRole::ListItem
                        | crate::display_source::ElementRole::Code
                        | crate::display_source::ElementRole::Caption
                        // `<hr>` 自己就是分隔线块的产生元素。以前没把它算进
                        // block_level，divider 块记在了外层 div 名下：div 被
                        // 当成“块自己”从容器链里排除，div 是盒子最后一块时
                        // 找不到底边，底部白边/底色会少一截。
                        | crate::display_source::ElementRole::Divider
                        | crate::display_source::ElementRole::Table
                        | crate::display_source::ElementRole::TableRow
                        | crate::display_source::ElementRole::TableCell
                )
            );
        if block_level {
            self.owner_stack.push(self.block_owner);
            self.block_owner = eid;
        }
        self.walk_node(n, style, parent, block);
        if block_level {
            self.block_owner = self.owner_stack.pop().unwrap_or(0);
        }
        if eid != 0 {
            self.source.exit(eid, self.blocks.len());
            self.element_stack.pop();
        }
    }

    fn begin(
        &mut self,
        kind: &'static str,
        level: Option<u32>,
        block: BlockStyle,
        nest: u32,
        ordered: bool,
        ordinal: Option<i64>,
    ) {
        self.flush();
        self.kind = kind;
        self.level = level;
        self.quote_container = false;
        self.align = block.align();
        self.no_indent = block.no_indent;
        self.nest = nest;
        self.ordered = ordered;
        self.ordinal = ordinal;
        self.text_shadow = self.pending_text_shadow.take();
    }

    /// `<br>`：沿用旧规则（折叠成一个空格），另记「这里要换行」。
    fn line_break(&mut self, style: Style) {
        if self.runs.is_empty() {
            // 块首的换行没有意义，旧规则同样丢弃
            return;
        }
        let (run, _, _) = self.append(" ", style, "\n", None, &[]);
        let len = units(&self.runs[run].text);
        if len == 0 {
            return;
        }
        self.hard_breaks.push((run, len - 1));
        self.marks.push(Mark {
            run,
            offset: len - 1,
            indent: 0,
        });
    }
}

#[cfg(test)]
#[path = "html_tests.rs"]
mod tests;
