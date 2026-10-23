// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use crate::dom::{Dom, Handle, attr, tag};
use crate::original_hyphen::English;
use html5ever::{
    Attribute, QualName,
    interface::tree_builder::{ElementFlags, NodeOrText, TreeSink},
    parse_document,
    tendril::TendrilSink,
};

pub struct Original {
    english: Option<English>,
    pub output: Vec<u8>,
    times: [u64; 5],
}
fn attribute(key: &str, value: &str) -> Attribute {
    Attribute {
        name: QualName::new(None, "".into(), key.into()),
        value: value.into(),
    }
}
fn set_attr(node: &Handle, key: &str, value: &str) {
    let mut attrs = node.attrs.borrow_mut();
    if let Some(a) = attrs.iter_mut().find(|a| &*a.name.local == key) {
        a.value = value.into();
    } else {
        attrs.push(attribute(key, value));
    }
}
fn whitespace(c: char) -> bool {
    matches!(c,'\u{0}'..='\u{20}'|'\u{a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}')
}
fn stylesheets(source: &str) -> Vec<String> {
    let lower = source.to_ascii_lowercase();
    let mut at = 0;
    let mut result = Vec::new();
    while let Some(found) = lower[at..].find("<?xml-stylesheet") {
        let start = at + found;
        let Some(end) = lower[start..].find('>') else {
            break;
        };
        at = start + end + 1;
        let line = &source[start..at];
        let lc = line.to_ascii_lowercase();
        let Some(href) = lc.find("href") else {
            continue;
        };
        let value = line[href + 4..].trim_start();
        let Some(value) = value.strip_prefix('=') else {
            continue;
        };
        let value = value.trim_start();
        if !value.starts_with(['\'', '"']) {
            continue;
        }
        let value = &value[1..];
        if let Some(end) = value.find(['\'', '"']) {
            if end > 0 {
                result.push(value[..end].to_owned());
            }
        }
    }
    result
}
pub(crate) fn sanitize_dom(dom: &Dom) {
        // Inspect the original arena so detached subtrees never enter the output.
        for node in dom.nodes.borrow().iter() {
            let name = tag(node);
            if matches!(
                name,
                "script"
                    | "noscript"
                    | "iframe"
                    | "frame"
                    | "frameset"
                    | "embed"
                    | "object"
                    | "applet"
                    | "base"
            ) || (name == "meta"
                && attr(node, "http-equiv")
                    .or_else(|| attr(node, "http_equiv"))
                    .unwrap_or_default()
                    .to_ascii_lowercase()
                    == "refresh")
            {
                dom.remove_from_parent(node);
                continue;
            }
            node.attrs
                .borrow_mut()
                .retain(|a| !a.name.local.to_ascii_lowercase().starts_with("on"));
            for a in node.attrs.borrow_mut().iter_mut() {
                if matches!(
                    &*a.name.local,
                    "href"
                        | "src"
                        | "xlink:href"
                        | "action"
                        | "formaction"
                        | "background"
                        | "poster"
                ) {
                    let value: String = a.value.chars().filter(|&c| !whitespace(c)).collect();
                    let value = value.to_ascii_lowercase();
                    if value.starts_with("javascript:")
                        || value.starts_with("vbscript:")
                        || value.starts_with("data:text/html")
                    {
                        a.value = "#".into();
                    }
                }
            }
        }
}
impl Original {
    pub fn new(dictionary: &[u8]) -> Self {
        Self {
            english: (!dictionary.is_empty()).then(|| English::new(dictionary)),
            output: Vec::new(),
            times: [0; 5],
        }
    }
    pub fn transform(&mut self, raw: &[u8]) -> Vec<u8> {
        let clock = std::time::Instant::now();
        let (bytes, id) = if raw.starts_with(&[0xff, 0xfe]) {
            (&raw[2..], 1)
        } else if raw.starts_with(&[0xfe, 0xff]) {
            (&raw[2..], 2)
        } else {
            (raw.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(raw), 0)
        };
        let source = crate::text::decode(bytes, id);
        let links = stylesheets(&source);
        self.times[0] = clock.elapsed().as_micros() as u64;
        let dom = parse_document(Dom::for_original(), Default::default()).one(source);
        self.times[1] = clock.elapsed().as_micros() as u64;
        sanitize_dom(&dom);
        let head = dom
            .nodes
            .borrow()
            .iter()
            .find(|n| tag(n) == "head")
            .cloned();
        if let Some(head) = head {
            for href in links.iter().rev() {
                let link = dom.create_element(
                    QualName::new(None, "http://www.w3.org/1999/xhtml".into(), "link".into()),
                    vec![
                        attribute("rel", "stylesheet"),
                        attribute("type", "text/css"),
                        attribute("href", href),
                    ],
                    ElementFlags::default(),
                );
                let first = head.children.borrow().first().cloned();
                if let Some(first) = first {
                    dom.append_before_sibling(&first, NodeOrText::AppendNode(link));
                } else {
                    dom.append(&head, NodeOrText::AppendNode(link));
                }
            }
        }
        self.times[2] = clock.elapsed().as_micros() as u64;
        if let Some(english) = &mut self.english {
            let body = dom
                .nodes
                .borrow()
                .iter()
                .find(|n| tag(n) == "body")
                .cloned();
            if let Some(body) = body {
                let mut stack = vec![(body, false)];
                while let Some((node, prose)) = stack.pop() {
                    let name = tag(&node);
                    if matches!(
                        name,
                        "script"
                            | "style"
                            | "pre"
                            | "code"
                            | "h1"
                            | "h2"
                            | "h3"
                            | "h4"
                            | "h5"
                            | "h6"
                    ) {
                        continue;
                    }
                    let prose = prose || matches!(name, "p" | "li" | "blockquote" | "div");
                    for (i, child) in node.children.borrow().iter().enumerate() {
                        if child.name.is_none() && !child.comment && prose {
                            let changed = {
                                let raw = child.text.borrow();
                                let (text, positions) = english.display(&raw);
                                if positions.is_empty() { None }
                                else { Some((text.into_owned(), positions)) }
                            };
                            if let Some((text, positions)) = changed {
                                *child.text.borrow_mut() = text;
                                set_attr(
                                    &node,
                                    &format!("data-gt-hyphens-{i}"),
                                    &serde_json::to_string(&positions).unwrap(),
                                );
                            }
                        } else if child.name.is_some() {
                            stack.push((child.clone(), prose));
                        }
                    }
                }
            }
        }
        self.times[3] = clock.elapsed().as_micros() as u64;
        let result = crate::original_serialize::serialize(&dom, self.english.is_some());
        self.times[4] = clock.elapsed().as_micros() as u64;
        for i in (1..5).rev() {
            self.times[i] -= self.times[i - 1];
        }
        result
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_original_open(data: *const u8, length: usize) -> *mut Original {
    Box::into_raw(Box::new(Original::new(unsafe {
        std::slice::from_raw_parts(data, length)
    })))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_original_transform(
    handle: *mut Original,
    data: *const u8,
    length: usize,
    out: *mut crate::GtScanResult,
) {
    let native = unsafe { &mut *handle };
    crate::result(
        native.transform(unsafe { std::slice::from_raw_parts(data, length) }),
        &mut native.output,
        out,
    );
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_original_close(handle: *mut Original) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_original_timings(handle: *mut Original, out: *mut crate::GtScanResult) {
    let native = unsafe { &mut *handle };
    crate::result(
        serde_json::to_vec(&native.times).unwrap(),
        &mut native.output,
        out,
    );
}
