// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 自定义属性按元素作用域求值。保留原声明，递归解析依赖，不以循环次数猜收敛。
use std::collections::{HashMap, HashSet};

pub(super) fn resolve_custom_properties(
    raw: &HashMap<String, String>,
    parent: &HashMap<String, String>,
) -> HashMap<String, String> {
    let mut resolver = Resolver {
        raw,
        parent,
        memo: HashMap::new(),
        stack: vec![],
        cyclic: HashSet::new(),
    };
    let mut result = parent.clone();
    for name in raw.keys() {
        match resolver.get(name) {
            Some(value) => {
                result.insert(name.clone(), value);
            }
            None => {
                result.remove(name);
            }
        }
    }
    result
}
struct Resolver<'a> {
    raw: &'a HashMap<String, String>,
    parent: &'a HashMap<String, String>,
    memo: HashMap<String, Option<String>>,
    stack: Vec<String>,
    cyclic: HashSet<String>,
}
impl Resolver<'_> {
    fn get(&mut self, name: &str) -> Option<String> {
        if let Some(value) = self.memo.get(name) {
            return value.clone();
        }
        let Some(raw) = self.raw.get(name) else {
            return self.parent.get(name).cloned();
        };
        if let Some(start) = self.stack.iter().position(|entry| entry == name) {
            self.cyclic.extend(self.stack[start..].iter().cloned());
            return None;
        }
        self.stack.push(name.to_owned());
        let raw = raw.clone();
        // CSS 的循环依赖也包含 fallback 中的引用，即使该 fallback 本次未被选中。
        for dependency in references(&raw) {
            if self.raw.contains_key(&dependency) {
                self.get(&dependency);
            }
        }
        let mut value = match raw.trim() {
            "initial" => None,
            "inherit" | "unset" | "revert" | "revert-layer" => self.parent.get(name).cloned(),
            _ => substitute(&raw, &mut |key| self.get(key)),
        };
        self.stack.pop();
        if self.cyclic.contains(name) {
            value = None;
        }
        self.memo.insert(name.to_owned(), value.clone());
        value
    }
}
pub(super) fn substitute_vars(value: &str, vars: &HashMap<String, String>) -> Option<String> {
    substitute(value, &mut |name| vars.get(name).cloned())
}

// 这里只替换真正的 var() token；引号、注释中的同名字样保持原样。
fn substitute(value: &str, lookup: &mut impl FnMut(&str) -> Option<String>) -> Option<String> {
    let mut output = String::new();
    let mut cursor = 0;
    while cursor < value.len() {
        let rest = &value[cursor..];
        if rest.starts_with('"') || rest.starts_with('\'') {
            let end = quoted_end(value, cursor)?;
            output.push_str(&value[cursor..end]);
            cursor = end;
        } else if rest.starts_with("/*") {
            let end = cursor + 2 + rest[2..].find("*/")? + 2;
            output.push_str(&value[cursor..end]);
            cursor = end;
        } else if rest.starts_with("var(") {
            let end = closing_parenthesis(value, cursor + 3)?;
            let inner = &value[cursor + 4..end];
            let comma = top_comma(inner);
            let name = inner[..comma.unwrap_or(inner.len())].trim();
            if !name.starts_with("--") {
                return None;
            }
            let replacement = lookup(name)
                .or_else(|| comma.and_then(|at| substitute(&inner[at + 1..], lookup)))?;
            output.push_str(&replacement);
            cursor = end + 1;
        } else {
            let ch = rest.chars().next()?;
            output.push(ch);
            cursor += ch.len_utf8();
        }
    }
    Some(output)
}
fn references(value: &str) -> Vec<String> {
    let mut result = vec![];
    let mut at = 0;
    while at < value.len() {
        if value[at..].starts_with("/*") {
            let Some(end) = value[at + 2..].find("*/") else {
                break;
            };
            at += end + 4;
            continue;
        }
        match value.as_bytes()[at] {
            b'"' | b'\'' => {
                let Some(end) = quoted_end(value, at) else {
                    break;
                };
                at = end;
                continue;
            }
            _ => {}
        }
        if value[at..].starts_with("var(") {
            if let Some(end) = closing_parenthesis(value, at + 3) {
                let inner = &value[at + 4..end];
                let name = inner[..top_comma(inner).unwrap_or(inner.len())].trim();
                if name.starts_with("--") {
                    result.push(name.to_owned());
                }
            }
        }
        at += value[at..].chars().next().unwrap().len_utf8();
    }
    result
}
fn quoted_end(value: &str, start: usize) -> Option<usize> {
    let quote = value.as_bytes()[start];
    let mut at = start + 1;
    while at < value.len() {
        let byte = value.as_bytes()[at];
        if byte == b'\\' {
            at += 2;
        } else if byte == quote {
            return Some(at + 1);
        } else {
            at += 1;
        }
    }
    None
}
fn closing_parenthesis(value: &str, start: usize) -> Option<usize> {
    let mut depth = 0;
    let mut at = start;
    while at < value.len() {
        match value.as_bytes()[at] {
            b'"' | b'\'' => {
                at = quoted_end(value, at)?;
                continue;
            }
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(at);
                }
            }
            _ => {}
        }
        at += 1;
    }
    None
}
fn top_comma(value: &str) -> Option<usize> {
    let mut at = 0;
    while at < value.len() {
        match value.as_bytes()[at] {
            b'"' | b'\'' => {
                at = quoted_end(value, at)?;
                continue;
            }
            b'(' => {
                at = closing_parenthesis(value, at)? + 1;
                continue;
            }
            b',' => return Some(at),
            _ => {}
        }
        at += 1;
    }
    None
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_dependencies_fallback_case_and_quotes() {
        let raw = HashMap::from([
            ("--A".into(), "red".into()),
            ("--b".into(), "var(--A)".into()),
        ]);
        let vars = resolve_custom_properties(&raw, &HashMap::new());
        assert_eq!(substitute_vars("var(--b)", &vars).as_deref(), Some("red"));
        assert_eq!(
            substitute_vars("var(--a, rgb(1,2,3))", &vars).as_deref(),
            Some(" rgb(1,2,3)")
        );
        assert_eq!(
            substitute_vars("'var(--b)'", &vars).as_deref(),
            Some("'var(--b)'")
        );
    }
    #[test]
    fn cycles_are_invalid_and_can_use_outer_fallback() {
        let raw = HashMap::from([
            ("--a".into(), "var(--b)".into()),
            ("--b".into(), "var(--a)".into()),
        ]);
        let vars = resolve_custom_properties(&raw, &HashMap::new());
        assert!(!vars.contains_key("--a"));
        assert!(!vars.contains_key("--b"));
        assert_eq!(
            substitute_vars("var(--a,red)", &vars).as_deref(),
            Some("red")
        );
    }
}
