//! 保留公式显示结构；整段 SVG 使用来源索引中的公式范围，不改变既有正文。
use crate::dom::Handle;

pub fn serialize(root: &Handle) -> String {
    enum Event { Open(Handle), Close(String) }
    let mut events = vec![Event::Open(root.clone())];
    let mut out = String::new();
    while let Some(event) = events.pop() {
        match event {
            Event::Close(tag) => { out.push_str("</"); out.push_str(&tag); out.push('>'); }
            Event::Open(node) => {
                let Some(name) = &node.name else {
                    if !node.comment { escape(&node.text.borrow(), &mut out); }
                    continue;
                };
                let tag = name.local.to_string();
                if matches!(tag.as_str(), "script" | "style" | "iframe" | "object") { continue; }
                out.push('<'); out.push_str(&tag);
                if tag == "math" { out.push_str(" xmlns=\"http://www.w3.org/1998/Math/MathML\""); }
                for attr in node.attrs.borrow().iter() {
                    let key: &str = attr.name.local.as_ref();
                    // 只序列化公式数据；资源链接和事件不会交给本地转换环境。
                    if key == "id" || key == "xmlns" || key == "href" || key == "src"
                        || key.starts_with("on") { continue; }
                    out.push(' '); out.push_str(key); out.push_str("=\"");
                    escape(&attr.value, &mut out); out.push('"');
                }
                out.push('>');
                events.push(Event::Close(tag));
                for child in node.children.borrow().iter().rev() {
                    events.push(Event::Open(child.clone()));
                }
            }
        }
    }
    out
}

fn escape(text: &str, out: &mut String) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"), '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"), '"' => out.push_str("&quot;"),
            _ => out.push(ch),
        }
    }
}
