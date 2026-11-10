// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 在实际纸面环境中重算样式；不再解析正文，也不改变任何正文坐标。
use super::selector::ElementRef;
use super::{Computed, Engine};
use serde_json::{Value, json};
use std::collections::HashMap;
pub fn evaluate(metadata: &Value) -> Value {
    let mut program = metadata["styleProgram"].clone();
    program["cssEnvironment"] = metadata["cssEnvironment"].clone();
    let Some(records) = program["nodes"].as_array() else {
        return json!({});
    };
    let dom = crate::dom::Dom::from_style_nodes(records);
    let Some(mut engine) = Engine::from_metadata(&program) else {
        return json!({});
    };
    let mut computed: HashMap<usize, Computed> = HashMap::new();
    let mut variables: HashMap<usize, HashMap<String, String>> = HashMap::new();
    let mut result = serde_json::Map::new();
    if !engine.font_faces().is_empty() {
        result.insert("fontFaces".into(), json!(engine.font_faces()));
    }
    let mut stack = vec![dom.document.clone()];
    while let Some(node) = stack.pop() {
        if node.name.is_some() {
            let parent = node.parent.borrow().upgrade().map(|n| n.id);
            let vars = parent
                .and_then(|id| variables.get(&id))
                .cloned()
                .unwrap_or_default();
            let (style, vars) = engine.compute(
                &ElementRef::new(node.clone()),
                parent.and_then(|id| computed.get(&id)),
                &vars,
            );
            let mut record = style.to_json();
            record["fontSizeDeclared"] = json!(style.font_size_declared);
            result.insert(node.id.to_string(), record);
            computed.insert(node.id, style);
            variables.insert(node.id, vars);
        }
        stack.extend(node.children.borrow().iter().rev().cloned());
    }
    Value::Object(result)
}
