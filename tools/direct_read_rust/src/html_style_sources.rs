// Copyright (c) 2026 GT Reader contributors. GPL-3.0-only, see LICENSE.
//! 按已解析 DOM 的真实顺序收集来源，注释或 script 字符串里的假 link 不参与样式。
use super::*;
pub(super) fn style_sources(dom: &Dom) -> Value {
    let mut result = vec![];
    let mut stack = vec![dom.document.clone()];
    while let Some(node) = stack.pop() {
        let name = tag(&node);
        if name == "style" {
            let text = node
                .children
                .borrow()
                .iter()
                .map(|n| n.text.borrow().clone())
                .collect::<String>();
            result.push(
                json!({"inline":true,"value":text,"media":attr(&node,"media").unwrap_or_default()}),
            );
        } else if name == "link" {
            let rel = attr(&node, "rel").unwrap_or_default().to_ascii_lowercase();
            let stylesheet = rel
                .split_ascii_whitespace()
                .any(|part| part == "stylesheet");
            let alternate = rel.split_ascii_whitespace().any(|part| part == "alternate");
            if stylesheet && !alternate && attr(&node, "disabled").is_none() {
                if let Some(href) = attr(&node, "href") {
                    result.push(json!({"inline":false,"value":href,"media":attr(&node,"media").unwrap_or_default()}));
                }
            }
        }
        if !ignored(name) {
            stack.extend(node.children.borrow().iter().rev().cloned());
        }
    }
    json!(result)
}

/// 条件样式带上重算用的元素属性，正文缓存通过摘要引用书内公共规则。
pub(super) fn attach(dom: &Dom, build: &Builder, source: &mut Value) {
    if build.source.enabled {
        let nodes = dom.nodes.borrow();
        // 普通目录和脚注锚点可能在段落中间，只有书内明确的章节才另起一页。
        let chapters: Vec<_> = build.source.elements.iter().filter_map(|element| {
            if !matches!(element.tag.as_str(), "section" | "article" | "div") {
                return None;
            }
            let node = nodes.get(element.node_id)?;
            let has_token = |key, value| {
                attr(node, key).is_some_and(|s| s.split_whitespace().any(|v| v == value))
            };
            if has_token("epub:type", "chapter") || has_token("role", "doc-chapter") {
                Some([element.first_block?, element.last_block?])
            } else {
                None
            }
        }).collect();
        source["spreadChapters"] = json!(chapters);
    }
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
        if let Some(body) = find(&dom.document, "body")
            && ["marginwidth", "marginheight", "leftmargin", "topmargin"]
                .iter()
                .any(|k| attr(&body, k).is_some())
        {
            source["bodyMargin"] = json!(true);
        }
        let mut resources = engine.resources();
        resources.sort();
        source["backgroundResources"] = json!(resources);
        if !engine.font_faces().is_empty() {
            source["fontFaces"] = json!(engine.font_faces());
        }
        if engine.needs_environment() {
            let mut program = json!({"nodes":dom.style_nodes(),"documentPath":build.metadata["documentPath"],"unifiedCss":true});
            if build.metadata["legacyMobi"] == true {
                program["legacyMobi"] = json!(true);
            }
            if let Some(book) = build.metadata.get("cssBook") {
                program["cssBook"] = book.clone();
                if build.metadata["cssFullScan"] == true {
                    program["cssFullScan"] = json!(true);
                }
            } else {
                program["cssSources"] = build.metadata["cssSources"].clone();
                program["cssFiles"] = build.metadata["cssFiles"].clone();
            }
            source["css"] = program;
        }
    }
}

impl Html {
    pub fn refs(&self) -> Value {
        let mut images = vec![];
        let mut links = vec![];
        let mut opening = true;
        let mut image_template = None;
        let mut opening_template = None;
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
            // 已有的资源遍历同时记录“第一项为图片、紧随章题”的模板。
            if opening {
                if image_template.is_some() && matches!(t, "h1" | "h2" | "h3" | "h4" | "h5" | "h6")
                {
                    opening_template = image_template.take();
                    opening = false;
                } else if t == "img" && image_template.is_none() {
                    if let Some(src) = source(&n) {
                        let parent = n.parent.borrow().upgrade();
                        let container = parent.as_ref().and_then(|p| attr(p, "class"));
                        image_template = Some(json!([src, container, attr(&n, "class")]));
                    }
                } else if t == "img"
                    || t == "svg"
                    || (!n.comment && !n.text.borrow().trim().is_empty())
                {
                    opening = false;
                }
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
        json!({"images":images,"links":links,"css":style_sources(&self.dom),"opening":opening_template})
    }
}
