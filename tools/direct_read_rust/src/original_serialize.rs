// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use crate::dom::{Dom, tag};

fn escape(out: &mut String, text: &str, attribute: bool) {
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '\u{a0}' => out.push_str("&nbsp;"),
            '"' if attribute => out.push_str("&quot;"),
            '<' if !attribute => out.push_str("&lt;"),
            '>' if !attribute => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
}
/// Iterative HTML serialization keeps deep documents safe to release and emit.
/// Attribute order, comments and text-node boundaries are preserved for locators.
pub fn serialize(dom: &Dom, hyphenated: bool) -> Vec<u8> {
    let root = &dom.document;
    let doctypes = dom.doctypes.borrow();
    let mut out = String::new();
    let mut stack = vec![(root.clone(), false, String::new())];
    while let Some((node, close, parent)) = stack.pop() {
        let name = tag(&node);
        let html = node
            .name
            .as_ref()
            .is_some_and(|n| &*n.ns == "http://www.w3.org/1999/xhtml");
        if close {
            out.push_str("</");
            out.push_str(name);
            out.push('>');
            continue;
        }
        if let Some((name, public, system)) = doctypes.get(&node.id) {
            out.push_str("<!DOCTYPE ");
            out.push_str(name);
            // Dart's first serialization emits quoted identifiers without PUBLIC
            // or SYSTEM. Its second parse (hyphenation) discards them. Emitting
            // them here would make browsers enter quirks mode and change layout.
            if !hyphenated && (!public.is_empty() || !system.is_empty()) {
                out.push_str(" \"");
                out.push_str(public);
                out.push_str("\" \"");
                out.push_str(system);
                out.push('"');
            }
            out.push('>');
            continue;
        }
        if node.comment {
            out.push_str("<!--");
            out.push_str(&node.text.borrow());
            out.push_str("-->");
            continue;
        }
        if name.is_empty() && node.id != 0 {
            if matches!(
                parent.as_str(),
                "style" | "script" | "xmp" | "iframe" | "noembed" | "noframes" | "noscript" | "plaintext"
            ) {
                out.push_str(&node.text.borrow());
            } else {
                escape(&mut out, &node.text.borrow(), false);
            }
            continue;
        }
        if !name.is_empty() {
            out.push('<');
            out.push_str(name);
            for a in node.attrs.borrow().iter() {
                out.push(' ');
                if let Some(prefix) = &a.name.prefix {
                    if !prefix.is_empty() {
                        out.push_str(prefix);
                        out.push(':');
                    }
                }
                out.push_str(&a.name.local);
                out.push_str("=\"");
                escape(&mut out, &a.value, true);
                out.push('"');
            }
            out.push('>');
            if !html
                || !matches!(
                    name,
                    "area"
                        | "base"
                        | "br"
                        | "col"
                        | "embed"
                        | "hr"
                        | "img"
                        | "input"
                        | "keygen"
                        | "link"
                        | "meta"
                        | "param"
                        | "source"
                        | "track"
                        | "wbr"
                )
            {
                stack.push((node.clone(), true, String::new()));
            }
        }
        let children = node.template.as_ref().unwrap_or(&node).children.borrow();
        if matches!(name, "pre" | "textarea" | "listing")
            && children.first().is_some_and(|n| {
                n.name.is_none() && !n.comment && n.text.borrow().starts_with('\n')
            })
        {
            out.push('\n');
        }
        for child in children.iter().rev() {
            stack.push((
                child.clone(),
                false,
                if html { name.to_owned() } else { String::new() },
            ));
        }
    }
    out.into_bytes()
}
