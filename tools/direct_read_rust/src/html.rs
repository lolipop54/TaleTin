// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
// Conversion mirrors the reader's existing block/run rules, including separate
// trimming at style boundaries. UTF-16 lengths are used for all reader positions.
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
            if t == "a"
                && (attr(&n, "epub:type")
                    .unwrap_or_default()
                    .contains("noteref")
                    || attr(&n, "role").unwrap_or_default().contains("doc-noteref"))
            {
                if let Some(href) = attr(&n, "href") {
                    links.push(href);
                }
            }
            stack.extend(n.children.borrow().iter().rev().cloned());
        }
        json!({"images":images,"links":links})
    }
    fn build(&self, metadata: Value, flags: u32) -> Builder {
        let mut build = Builder::new(metadata, flags | if self.optimized { 4 } else { 0 });
        if let Some(body) = find(&self.dom.document, "body") {
            build.walk_all(&body, Style::default());
        }
        build.flush();
        while !build.blocks.is_empty()
            && build.blocks[0]["kind"] != "image"
            && build.blocks[0].get("runs").is_none()
        {
            build.blocks.remove(0);
        }
        build
    }
    pub fn convert(&self, metadata: Value, flags: u32) -> Value {
        let anchors = metadata.get("anchors").cloned();
        let anchor_metadata = metadata.clone();
        let build = self.build(metadata, flags);
        let mut result = json!({"blocks":build.blocks,"tables":build.tables,"heading":build.heading,"warnings":build.warnings,
            "length":build.length,"singleImage":build.single_image,"pieces":build.maps});
        if anchors.is_some() {
            result["tocHeadings"] = json!(build.toc_headings);
        }
        if build.map {
            result["dom"] = self.export(&self.dom.document);
        }
        if anchors.as_ref().is_some_and(|a| a.as_array().is_some_and(|a| !a.is_empty())) {
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
#[derive(Clone, Copy, Default)]
struct Style {
    bold: bool,
    italic: bool,
    suppress_bold: bool,
    suppress_italic: bool,
}
struct Run {
    text: String,
    style: Style,
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
    maps: Vec<Value>,
    warnings: Vec<&'static str>,
    heading: Option<String>,
    seq: usize,
    kind: &'static str,
    level: Option<u32>,
    target: Option<String>,
    length: usize,
    count: usize,
    single_image: Option<String>,
    toc_headings: Vec<Value>,
}
fn units(s: &str) -> usize {
    s.encode_utf16().count()
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
impl Builder {
    fn new(metadata: Value, flags: u32) -> Self {
        Self {
            metadata,
            stats: flags & 1 != 0,
            optimized: flags & 4 != 0,
            map: flags & 2 != 0,
            blocks: vec![],
            tables: vec![],
            runs: vec![],
            pieces: vec![],
            maps: vec![],
            warnings: vec![],
            heading: None,
            seq: 0,
            kind: "paragraph",
            level: None,
            target: None,
            length: 0,
            count: 0,
            single_image: None,
            toc_headings: vec![],
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
    fn style(&mut self, node: &Handle, mut s: Style) -> Style {
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
        s
    }
    fn walk_all(&mut self, node: &Handle, style: Style) {
        for (i, child) in node.children.borrow().iter().enumerate() {
            self.walk(child, style, Some((node, i)));
        }
    }
    fn walk(&mut self, n: &Handle, style: Style, parent: Option<(&Handle, usize)>) {
        if n.name.is_none() {
            if !n.comment {
                self.text(n.text.borrow().as_str(), style, Some(n), parent);
            }
            return;
        }
        let tag = tag(n);
        if tag == "style" || tag == "link" {
            self.warning();
            return;
        }
        if ignored(tag) {
            return;
        }
        if tag == "table" {
            self.table(n, style);
            return;
        }
        let style = self.style(n, style);
        match tag {
            "br" => {
                self.text("\n", style, None, None);
                return;
            }
            "img" | "image" => {
                self.image(n);
                return;
            }
            "svg" => {
                if let Some(image) = find(n, "image") {
                    self.image(&image);
                }
                return;
            }
            "hr" => {
                self.flush();
                self.record("divider", 1, None);
                if !self.stats {
                    let id = self.next();
                    self.blocks.push(json!({"id":id,"kind":"divider"}));
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
        let kind = match tag {
            "p" | "dd" | "dt" | "figcaption" | "pre" | "blockquote" | "td" | "th" => {
                Some("paragraph")
            }
            "li" => Some("listItem"),
            _ => None,
        };
        if level.is_some() || kind.is_some() {
            self.flush();
            self.kind = if level.is_some() {
                "heading"
            } else {
                kind.unwrap()
            };
            self.level = level;
            self.walk_all(n, style);
            self.flush();
            return;
        }
        if boundary(tag) {
            self.flush();
            self.walk_all(n, style);
            return;
        }
        if tag == "a"
            && self.target.is_none()
            && (attr(n, "epub:type").unwrap_or_default().contains("noteref")
                || attr(n, "role").unwrap_or_default().contains("doc-noteref"))
        {
            if let Some(href) = attr(n, "href") {
                self.target = self.metadata["links"][href].as_str().map(str::to_owned);
            }
        }
        self.walk_all(n, style);
    }
    fn text(
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
        let mut normalized = collapse(&clean);
        if normalized.is_empty() || (normalized == " " && self.runs.is_empty()) {
            return;
        }
        let merges = self
            .runs
            .last()
            .is_some_and(|r| r.style.bold == style.bold && r.style.italic == style.italic);
        if self.map {
            self.pieces.push(json!([
                node.map(|n| n.id),
                clean,
                if merges {
                    self.runs.len() - 1
                } else {
                    self.runs.len()
                },
                breaks
            ]));
        }
        if merges {
            let last = self.runs.last_mut().unwrap();
            if last.text.ends_with(' ') && normalized.starts_with(' ') {
                normalized.remove(0);
            }
            last.text.push_str(&normalized);
        } else {
            self.runs.push(Run {
                text: normalized,
                style,
            });
        }
    }
    fn flush(&mut self) {
        let kind = self.kind;
        let level = self.level.take();
        let target = self.target.take();
        self.kind = "paragraph";
        // Statistics need the same style-boundary trimming and UTF-16 count,
        // but no second vector or owned copy of every trimmed run.
        if self.stats && self.optimized {
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
            return;
        }
        let runs = std::mem::take(&mut self.runs)
            .into_iter()
            .filter_map(|r| {
                let text = r.text.trim_matches(|c| c == ' ' || c == '\n').to_owned();
                if text.is_empty() {
                    None
                } else {
                    Some(Run {
                        text,
                        style: r.style,
                    })
                }
            })
            .collect::<Vec<_>>();
        let pieces = std::mem::take(&mut self.pieces);
        if runs.is_empty() {
            return;
        }
        if self.heading.is_none() && (kind == "paragraph" || kind == "heading") {
            self.heading = Some(runs.iter().map(|r| r.text.as_str()).collect());
        }
        if kind == "heading" && self.metadata.get("anchors").is_some() {
            let title: String = runs.iter().map(|r| r.text.as_str()).collect();
            self.toc_headings.push(json!([title, self.length]));
        }
        self.record(
            kind,
            1 + runs.iter().map(|r| units(&r.text)).sum::<usize>(),
            None,
        );
        if self.stats {
            return;
        }
        let id = self.next();
        let mut block = json!({"id":id,"kind":kind,"runs":runs.iter().map(|r| {
            if !r.style.bold && !r.style.italic { json!(r.text) } else { let mut run=json!({"text":r.text});
                if r.style.bold { run["bold"]=json!(true); } if r.style.italic { run["italic"]=json!(true); } run }
        }).collect::<Vec<_>>()});
        if let Some(level) = level {
            block["level"] = json!(level);
        }
        if let Some(target) = target {
            block["target"] = json!(target);
        }
        self.blocks.push(block);
        if self.map {
            self.maps.push(json!([id, pieces]));
        }
    }
    fn image(&mut self, n: &Handle) {
        let Some(src) = source(n) else {
            return;
        };
        let resolved = self.metadata["images"][src].clone();
        if resolved.is_null() {
            return;
        }
        self.flush();
        self.record("image", 1, resolved["resource"].as_str().map(str::to_owned));
        if self.stats {
            return;
        }
        let mut block = resolved;
        block["id"] = json!(self.next());
        block["kind"] = json!("image");
        if let Some(alt) = attr(n, "alt") {
            block["alt"] = json!(alt);
        }
        self.blocks.push(block);
    }
    fn table(&mut self, table: &Handle, style: Style) {
        self.flush();
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
            self.tables
                .push(json!({"cells":cells,"columns":columns,"rows":rows}));
        }
    }
    fn table_visit(
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
        if t == "tr" {
            *row += 1;
            for c in n.children.borrow().iter() {
                self.table_visit(c, style, row, columns, rows, cells, occupied);
            }
            self.flush();
        } else if t == "td" || t == "th" {
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
            self.walk(n, style, None);
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
        } else if matches!(t, "thead" | "tbody" | "tfoot") {
            for c in n.children.borrow().iter() {
                self.table_visit(c, style, row, columns, rows, cells, occupied);
            }
        } else {
            self.walk(n, style, None);
        }
    }
}
