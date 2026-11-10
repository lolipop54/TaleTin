//! 修复有明确反向链接的脚注占位地址；不按编号猜注释。
use crate::dom::{Dom, Handle, attr, tag};
use html5ever::{Attribute, QualName};

fn text(node: &Handle) -> String {
    let mut result = node.text.borrow().clone();
    for child in node.children.borrow().iter() {
        result.push_str(&text(child));
    }
    result
}
fn set(node: &Handle, key: &str, value: &str) {
    let mut attrs = node.attrs.borrow_mut();
    if let Some(a) = attrs.iter_mut().find(|a| &*a.name.local == key) {
        a.value = value.into();
    } else {
        attrs.push(Attribute {
            name: QualName::new(None, "".into(), key.into()),
            value: value.into(),
        });
    }
}
pub(crate) fn repair(dom: &Dom) {
    let nodes = dom.nodes.borrow();
    for node in nodes.iter().filter(|n| tag(n) == "a") {
        let href = attr(node, "href").unwrap_or_default();
        if href.len() < 4 || !href.chars().all(|c| c == 'X') {
            continue;
        }
        let marker = text(node);
        if marker.trim().is_empty() || marker.trim().chars().count() > 8 {
            continue;
        }
        let mut owner = Some(node.clone());
        let mut reference = None;
        while let Some(current) = owner {
            if let Some(id) = attr(&current, "id") {
                reference = Some(id);
                break;
            }
            if matches!(tag(&current), "p" | "div" | "li" | "body") {
                break;
            }
            owner = current.parent.borrow().upgrade();
        }
        let Some(reference) = reference.filter(|id| id.contains("footnote")) else {
            continue;
        };
        let matches: Vec<_> = nodes
            .iter()
            .filter(|n| {
                tag(n) == "a"
                    && text(n).trim() == marker.trim()
                    && attr(n, "href")
                        .is_some_and(|h| h.split_once('#').is_some_and(|(_, f)| f == reference))
            })
            .collect();
        if matches.len() != 1 {
            continue;
        }
        let backlink = matches[0];
        let mut paragraph = backlink.parent.borrow().upgrade();
        while let Some(p) = paragraph {
            if matches!(tag(&p), "p" | "li" | "dd" | "aside") {
                if text(&p).trim().len() <= marker.trim().len() {
                    break;
                }
                let id = attr(&p, "id").unwrap_or_else(|| format!("gt-note-for-{reference}"));
                if nodes
                    .iter()
                    .any(|n| n.id != p.id && attr(n, "id").as_deref() == Some(&id))
                {
                    break;
                }
                set(&p, "id", &id);
                set(node, "href", &format!("#{id}"));
                break;
            }
            if tag(&p) == "body" {
                break;
            }
            paragraph = p.parent.borrow().upgrade();
        }
    }
}
