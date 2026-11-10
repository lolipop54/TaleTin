//! 章节样式表：块与片段只带整数编号，样式记录去重后随正文一起输出。
//!
//! 这一版是**双写**：旧显示字段（`align`、`box`、`tsh`、`list`、片段上的粗体/颜色等）
//! 原样保留，阅读器照旧读它们；样式表只是多出来的一份，供后续「测量改读样式表」使用。
//! 映射规则必须与 Dart 侧 `legacy_style_adapter.dart` 完全一致，否则两边编号和内容对不上；
//! `test/engine/rust_style_table_test.dart` 会逐章对照两边的表。
//!
//! 单位约定：旧盒子数组是「百分之一 em」的整数，这里换成保留单位的 `em` 值，
//! 像素换算仍留给排版上下文（与 Dart 的 `EmLength(raw / 100)` 相同）。

use serde_json::{Map, Value, json};
use std::collections::HashMap;

/// 样式表格式版本，与 Dart 的 `styleSchemaVersion` 保持一致。
const STYLE_SCHEMA_VERSION: i64 = 1;

pub struct StyleTable {
    records: Vec<Value>,
    index: HashMap<String, u32>,
}

impl StyleTable {
    /// 空表：0 号固定是空样式，块/片段没有样式时引用它。
    pub fn new() -> Self {
        let mut index = HashMap::new();
        index.insert("{}".to_string(), 0);
        Self {
            records: vec![json!({})],
            index,
        }
    }

    /// 登记一份样式；内容相同的复用同一个编号。
    pub fn intern(&mut self, record: Value) -> u32 {
        let empty = record.as_object().map_or(true, |map| map.is_empty());
        if empty {
            return 0;
        }
        let key = serde_json::to_string(&record).unwrap_or_default();
        if let Some(id) = self.index.get(&key) {
            return *id;
        }
        let id = self.records.len() as u32;
        self.index.insert(key, id);
        self.records.push(record);
        id
    }

    pub fn to_json(&self) -> Value {
        json!({"v": STYLE_SCHEMA_VERSION, "styles": self.records})
    }
}

impl Default for StyleTable {
    fn default() -> Self {
        Self::new()
    }
}

/// 给一章的所有块挂上样式编号，返回可直接放进结果的样式表。
pub fn attach(blocks: &mut [Value]) -> Value {
    attach_with_elements(blocks, &HashMap::new()).0
}

/// 同时登记块/片段样式和元素（容器）样式。元素样式供显示树读取背景、边框、
/// 内边距和文字继承；返回每个 DOM 节点对应的样式编号。
pub fn attach_with_elements(
    blocks: &mut [Value],
    elements: &HashMap<usize, Value>,
) -> (Value, HashMap<usize, u32>) {
    let mut table = StyleTable::new();
    for block in blocks.iter_mut() {
        let Some(object) = block.as_object_mut() else {
            continue;
        };
        let record = block_style(object);
        let id = table.intern(record);
        if id > 0 {
            object.insert("sid".to_string(), json!(id));
        }
        if let Some(Value::Object(parent)) = object.get_mut("parentBox") {
            let id = table.intern(block_style(parent));
            parent.remove("box");
            parent.insert("sid".to_string(), json!(id));
        }
        if let Some(Value::Array(runs)) = object.get_mut("runs") {
            for run in runs.iter_mut() {
                let Some(run_object) = run.as_object_mut() else {
                    continue;
                };
                let record = run_style(run_object);
                let id = table.intern(record);
                if id > 0 {
                    run_object.insert("sid".to_string(), json!(id));
                }
            }
        }
    }
    let mut ids = HashMap::new();
    let mut nodes: Vec<usize> = elements.keys().copied().collect();
    // 元素样式按节点编号稳定登记；HashMap 的遍历顺序不能进缓存身份。
    nodes.sort_unstable();
    for node_id in nodes {
        let style = &elements[&node_id];
        let id = table.intern(style.clone());
        ids.insert(node_id, id);
    }
    (table.to_json(), ids)
}

fn em(raw_hundredths: i64) -> Value {
    json!({"u": "em", "v": raw_hundredths as f64 / 100.0})
}

fn px(value: f64) -> Value {
    json!({"u": "px", "v": value})
}

fn block_style(block: &Map<String, Value>) -> Value {
    let mut style = Map::new();
    let text = text_style(block);
    if !text.is_empty() {
        style.insert("t".to_string(), Value::Object(text));
    }
    let box_style = box_style(block);
    if !box_style.is_empty() {
        style.insert("b".to_string(), Value::Object(box_style));
    }
    let mut size = Map::new();
    for (field, key) in [("iw", "w"), ("imw", "maxw")] {
        if let Some(value) = block.get(field).and_then(image_length) {
            size.insert(key.to_owned(), value);
        }
    }
    if !size.is_empty() {
        style.insert("s".to_owned(), Value::Object(size));
    }
    let block_style = block_flow_style(block);
    if !block_style.is_empty() {
        style.insert("k".to_string(), Value::Object(block_style));
    }
    Value::Object(style)
}

/// 块上的文字样式：文字阴影、代码块保留空白。
fn text_style(block: &Map<String, Value>) -> Map<String, Value> {
    let mut text = Map::new();
    if let Some(Value::Array(shadow)) = block.get("tsh") {
        if shadow.len() >= 4 {
            let value = |index: usize| shadow[index].as_i64().unwrap_or(0);
            text.insert(
                "sh".to_string(),
                json!([{
                    "x": em(value(0)),
                    "y": em(value(1)),
                    "b": em(value(2)),
                    "c": value(3),
                }]),
            );
        }
    }
    if block.get("kind").and_then(Value::as_str) == Some("code") {
        text.insert("wsp".to_string(), json!("pre"));
    }
    // 字距／词距：旧字段里已经是相对字号的小数（0.05 表示 0.05em）。
    if let Some(value) = block.get("lsp").and_then(Value::as_f64) {
        text.insert("ls".to_string(), json!({"u": "em", "v": value}));
    }
    if let Some(value) = block.get("wsp").and_then(Value::as_f64) {
        text.insert("ws".to_string(), json!({"u": "em", "v": value}));
    }
    text
}

/// 图片显式宽高：`[数值, 单位]`（1 百分比、2 em、3 px，数值是单位的百分之一）。
fn image_length(spec: &Value) -> Option<Value> {
    let list = spec.as_array()?;
    if list.len() < 2 {
        return None;
    }
    let value = list[0].as_i64().unwrap_or(0);
    match list[1].as_i64().unwrap_or(0) {
        1 => Some(json!({"u": "%", "v": value as f64 / 10000.0})),
        2 => Some(json!({"u": "em", "v": value as f64 / 100.0})),
        3 => Some(json!({"u": "px", "v": value as f64 / 100.0})),
        _ => None,
    }
}

/// 盒子：背景、四边边框（宽度/线型/颜色）、圆角、阴影、内边距。
///
/// 与 Dart 的 `_boxStyleOf` 一样：全零的字段不写；四边宽度全为 0 时不产生边框。
fn box_style(block: &Map<String, Value>) -> Map<String, Value> {
    let mut out = Map::new();
    let Some(Value::Array(raw)) = block.get("box") else {
        return out;
    };
    if raw.len() < 18 {
        return out;
    }
    let get = |index: usize| raw[index].as_i64().unwrap_or(0);

    let background = get(0);
    if background != 0 {
        out.insert("bg".to_string(), json!({"c": background}));
    }

    let padding = [get(14), get(15), get(16), get(17)];
    if padding.iter().any(|value| *value != 0) {
        out.insert(
            "p".to_string(),
            json!({"t": em(padding[0]), "r": em(padding[1]), "b": em(padding[2]), "l": em(padding[3])}),
        );
    }

    let widths = [get(1), get(2), get(3), get(4)];
    if widths.iter().any(|value| *value != 0) {
        let border_styles = if raw.len() >= 22 {
            [get(18), get(19), get(20), get(21)]
        } else {
            [1, 1, 1, 1]
        };
        let color = get(5);
        let side = |index: usize| {
            let mut side = Map::new();
            if widths[index] != 0 {
                side.insert("w".to_string(), em(widths[index]));
            }
            side.insert("s".to_string(), json!(line_style(border_styles[index])));
            side.insert("c".to_string(), json!(color));
            Value::Object(side)
        };
        out.insert(
            "b".to_string(),
            json!({"t": side(0), "r": side(1), "b": side(2), "l": side(3)}),
        );
    }

    let radii = [get(6), get(7), get(8), get(9)];
    if radii.iter().any(|value| *value != 0) {
        let mut corners = Map::new();
        for (key, value) in ["tl", "tr", "br", "bl"].into_iter().zip(radii) {
            if value != 0 {
                corners.insert(key.to_string(), em(value));
            }
        }
        out.insert("r".to_string(), Value::Object(corners));
    }

    let (x, y, blur) = (get(10), get(11), get(12));
    if x != 0 || y != 0 || blur != 0 {
        out.insert(
            "sh".to_string(),
            json!([{"x": em(x), "y": em(y), "b": em(blur), "c": get(13)}]),
        );
    }
    out
}

/// 块级：对齐、书里写的 `text-indent:0`、列表标记类型。
fn block_flow_style(block: &Map<String, Value>) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(align) = block.get("align").and_then(Value::as_str) {
        if matches!(align, "center" | "right" | "left") {
            out.insert("ta".to_string(), json!(align));
        }
    }
    if block.get("noIndent").and_then(Value::as_bool) == Some(true) {
        out.insert("ti".to_string(), px(0.0));
    }
    if let Some(list) = block.get("list").and_then(Value::as_i64) {
        if let Some(name) = list_style_name(list) {
            out.insert("ls".to_string(), json!({"t": name}));
        }
    }
    // 四边外边距：旧字段是百分之一 em 的四个整数，全零不写。
    if let Some(Value::Array(margin)) = block.get("mg") {
        if margin.len() >= 4 {
            let value = |index: usize| margin[index].as_i64().unwrap_or(0);
            if (0..4).any(|index| value(index) != 0) {
                out.insert(
                        "m".to_string(),
                        json!({"t": em(value(0)), "r": em(value(1)), "b": em(value(2)), "l": em(value(3))}),
                    );
            }
        }
    }
    out
}

fn run_style(run: &Map<String, Value>) -> Value {
    let mut text = Map::new();
    if run.get("bold").and_then(Value::as_bool) == Some(true) {
        text.insert("fw".to_string(), json!(700));
    }
    if run.get("italic").and_then(Value::as_bool) == Some(true) {
        text.insert("fy".to_string(), json!("italic"));
    }
    if let Some(color) = run.get("c").and_then(Value::as_i64) {
        text.insert("c".to_string(), json!(color));
    }
    if let Some(size) = run.get("fs").and_then(Value::as_f64) {
        if size != 1.0 {
            text.insert("fs".to_string(), json!({"u": "em", "v": size}));
        }
    }
    if run.get("sup").and_then(Value::as_bool) == Some(true) {
        text.insert("va".to_string(), json!("super"));
    } else if run.get("sub").and_then(Value::as_bool) == Some(true) {
        text.insert("va".to_string(), json!("sub"));
    }
    let mut lines: Vec<&str> = Vec::new();
    if run.get("st").and_then(Value::as_bool) == Some(true) {
        lines.push("lineThrough");
    }
    if run.get("u").and_then(Value::as_bool) == Some(true) {
        lines.push("underline");
    }
    if !lines.is_empty() {
        // Dart 侧对装饰线名排序（`[line.name]..sort`），这里保持同样顺序。
        lines.sort_unstable();
        text.insert("d".to_string(), json!({"l": lines}));
    }
    if text.is_empty() {
        return json!({});
    }
    json!({"t": text})
}

fn line_style(code: i64) -> &'static str {
    match code {
        2 => "dashed",
        3 => "dotted",
        _ => "solid",
    }
}

/// 列表标记编码（见 `ContentBlock.listStyle`）→ 样式表里的类型名。
fn list_style_name(code: i64) -> Option<&'static str> {
    Some(match code {
        0 => "none",
        1 => "decimal",
        2 => "lowerAlpha",
        3 => "upperAlpha",
        4 => "lowerRoman",
        5 => "upperRoman",
        6 => "disc",
        7 => "circle",
        8 => "square",
        _ => return None,
    })
}
