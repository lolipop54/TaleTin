// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
// TOC queries need a few positions, not the entire DOM/source-piece graph in
// Dart. Offsets mirror DomTextMapBuilder's per-run whitespace/trim rules.
use serde_json::{Value, json};
use crate::dom::{Dom, attr, tag};
use std::collections::{HashMap, HashSet};

fn units(text: &str) -> usize {
    text.encode_utf16().count()
}
fn trim_space(c: char) -> bool {
    super::html::html_space(c) || c == '\u{85}'
}
fn block_text(block: &Value) -> String {
    block["runs"]
        .as_array()
        .map(|runs| {
            runs.iter()
                .map(|r| r.as_str().or_else(|| r["text"].as_str()).unwrap_or(""))
                .collect()
        })
        .unwrap_or_default()
}

pub fn positions(dom: &Dom, raw_blocks: &[Value], raw_maps: &[Value], wanted: &[Value]) -> Value {
    let mut blocks = HashMap::new();
    let mut total = 0;
    for block in raw_blocks {
        let text = block_text(block);
        blocks.insert(block["id"].as_str().unwrap(), (total, text.clone()));
        total += units(&text) + 1;
    }
    let mut segments = HashMap::<usize, (String, usize)>::new();
    for map in raw_maps {
        let block = map[0].as_str().unwrap();
        let pieces = map[1].as_array().unwrap();
        let mut from = 0;
        let mut block_start = 0;
        let mut joined = String::new();
        while from < pieces.len() {
            let mut to = from + 1;
            while to < pieces.len() && pieces[to][2] == pieces[from][2] {
                to += 1;
            }
            let mut run = String::new();
            let mut spans = Vec::new();
            let mut run_units = 0;
            let mut previous_space = false;
            for p in &pieces[from..to] {
                let mut text = super::html::collapse(p[1].as_str().unwrap());
                if previous_space && text.starts_with(' ') {
                    text.remove(0);
                }
                let length = units(&text);
                spans.push((p[0].as_u64(), run_units, length));
                if !text.is_empty() {
                    previous_space = text.ends_with(' ');
                }
                run_units += length;
                run.push_str(&text);
            }
            let leading = units(&run) - units(run.trim_start_matches(trim_space));
            let text = run.trim_matches(trim_space);
            let limit = leading + units(text);
            for (node, start, length) in spans {
                let a = start.max(leading);
                let end = (start + length).min(limit);
                if let Some(node) = node {
                    if end > a {
                        segments
                            .insert(node as usize, (block.to_owned(), block_start + a - leading));
                    }
                }
            }
            block_start += units(text);
            joined.push_str(text);
            from = to;
        }
        // Retain the old implementation for a document whose source pieces do
        // not reproduce the converted block. Never publish guessed positions.
        if blocks.get(block).is_none_or(|(_, text)| *text != joined) {
            return json!({"ok":false});
        }
    }
    let wanted: HashSet<_> = wanted.iter().filter_map(Value::as_str).collect();
    let mut ids = HashMap::new();
    let mut names = HashMap::new();
    let mut order = Vec::new();
    let mut pending = vec![dom.document.clone()];
    while let Some(node) = pending.pop() {
        let id = node.id;
        let id_value = attr(&node, "id");
        if let Some(value) = &id_value {
            if wanted.contains(value.as_str()) {
                ids.entry(value.clone()).or_insert(id);
            }
        }
        if id_value.is_some() || tag(&node) == "a" {
            if let Some(value) = attr(&node, "name") {
                if wanted.contains(value.as_str()) {
                    names.entry(value).or_insert(id);
                }
            }
        }
        order.push(id);
        pending.extend(node.children.borrow().iter().rev().cloned());
    }
    // Id has priority even when its element has no following text. A missing
    // position must not silently switch to an earlier a[name] with that value.
    for (name, id) in names {
        ids.entry(name).or_insert(id);
    }
    let targets: HashSet<_> = ids.values().copied().collect();
    let mut located = HashMap::new();
    let mut next = None;
    for node in order.into_iter().rev() {
        if let Some(segment) = segments.get(&node) {
            next = Some(segment.clone());
        }
        if targets.contains(&node) {
            located.insert(node, next.clone());
        }
    }
    let mut points = serde_json::Map::new();
    let mut used_blocks = serde_json::Map::new();
    for (name, node) in ids {
        let point = match located.get(&node).and_then(Option::as_ref) {
            Some((block, offset)) => {
                let (start, text) = &blocks[block.as_str()];
                used_blocks
                    .entry(block.clone())
                    .or_insert(json!([start, text]));
                json!([block, offset])
            }
            None => Value::Null,
        };
        points.insert(name.to_owned(), point);
    }
    json!({"ok":true,"total":total,"points":points,"blocks":used_blocks})
}
