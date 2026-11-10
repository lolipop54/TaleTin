// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
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
