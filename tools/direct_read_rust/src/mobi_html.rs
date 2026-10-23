// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use crate::dom::{Dom, attr, tag};
use html5ever::{
    interface::tree_builder::{NodeOrText, TreeSink},
    parse_document,
    tendril::TendrilSink,
    tree_builder::TreeBuilderOpts,
};
use serde_json::{Value, json};

/// Only parse/serialize HTML here. Dart retains URI, split-anchor and media
/// rules, so importing MOBI does not introduce a second set of link semantics.
pub struct MobiHtml {
    dom: Dom,
    pub output: Vec<u8>,
}
// Every tree's Rc/RefCell graph is private to this owner. Rayon moves whole
// trees between workers; a tree is never shared or accessed concurrently.
unsafe impl Send for MobiHtml {}
impl MobiHtml {
    pub fn new(input: &[u8]) -> Self {
        let options = html5ever::ParseOpts {
            tree_builder: TreeBuilderOpts {
                // package:html's document parser treats noscript as raw text.
                scripting_enabled: true,
                ..Default::default()
            },
            ..Default::default()
        };
        let source = String::from_utf8_lossy(input);
        // html5ever consumes one leading BOM; Dart's String parser preserves
        // it as body text. An extra parser-only BOM retains that exact value.
        let source = if source.starts_with('\u{feff}') {
            format!("\u{feff}{source}")
        } else { source.into_owned() };
        let dom = parse_document(Dom::for_original(), options).one(source);
        Self {
            dom,
            output: Vec::new(),
        }
    }
    pub fn refs(&self) -> Vec<Value> {
        let mut result = Vec::new();
        let mut pending = vec![self.dom.document.clone()];
        while let Some(node) = pending.pop() {
            let href = attr(&node, "href");
            let src = attr(&node, "src");
            let media = attr(&node, "media");
            let style = if tag(&node) == "style" {
                let mut text = String::new();
                let mut children = node
                    .children
                    .borrow()
                    .iter()
                    .rev()
                    .cloned()
                    .collect::<Vec<_>>();
                while let Some(child) = children.pop() {
                    if child.name.is_none() && !child.comment {
                        text.push_str(&child.text.borrow());
                    }
                    children.extend(child.children.borrow().iter().rev().cloned());
                }
                Some(text)
            } else {
                None
            };
            if href.is_some() || src.is_some() || media.is_some() || style.is_some() {
                result.push(json!([node.id, href, src, media, style]));
            }
            // Match querySelectorAll: template contents are not descendants of
            // the template element, and discarded parser nodes are not visited.
            pending.extend(node.children.borrow().iter().rev().cloned());
        }
        result
    }
    pub fn finish(&self, edits: &[u8]) -> Vec<u8> {
        let edits: Vec<(usize, String, String)> = serde_json::from_slice(edits).unwrap();
        self.finish_edits(edits)
    }
    pub fn finish_edits(&self, edits: Vec<(usize, String, String)>) -> Vec<u8> {
        for (id, key, value) in edits {
            let node = self.dom.nodes.borrow()[id].clone();
            if key == "styleText" {
                node.children.borrow_mut().clear();
                self.dom.append(&node, NodeOrText::AppendText(value.into()));
            } else if let Some(a) = node
                .attrs
                .borrow_mut()
                .iter_mut()
                .find(|a| a.name.prefix.is_none() && &*a.name.local == key)
            {
                a.value = value.into();
            }
        }
        crate::original_serialize::serialize(&self.dom, false)
    }
}
