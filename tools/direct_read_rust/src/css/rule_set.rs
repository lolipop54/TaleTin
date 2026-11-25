//! 只按右端匹配条件过滤候选。层叠和伪类仍由原匹配器处理。
use super::parser::Stylesheet;
use super::selector::{CssSelectorImpl, ElementRef};
use selectors::parser::{Component, Selector};
use std::collections::HashMap;

type Branch = (usize, usize);

#[derive(Default)]
pub(super) struct RuleSet {
    ids: HashMap<String, Vec<Branch>>,
    classes: HashMap<String, Vec<Branch>>,
    tags: HashMap<String, Vec<Branch>>,
    common: Vec<Branch>,
}

impl RuleSet {
    pub(super) fn new(sheet: &Stylesheet) -> Self {
        let mut set = Self::default();
        for (rule, entry) in sheet.rules.iter().enumerate() {
            for (index, selector) in entry.selectors.slice().iter().enumerate() {
                set.bucket(selector).push((rule, index));
            }
        }
        set
    }
    fn bucket(&mut self, selector: &Selector<CssSelectorImpl>) -> &mut Vec<Branch> {
        // iter() 在第一个组合符处结束，绝不能用祖先的类或 ID 排除当前元素。
        let mut class = None;
        let mut tag = None;
        for component in selector.iter() {
            match component {
                Component::ID(id) => return self.ids.entry(id.0.to_string()).or_default(),
                Component::Class(name) => class = Some(&name.0),
                Component::LocalName(name) => tag = Some(&name.lower_name.0),
                _ => {}
            }
        }
        if let Some(name) = class {
            self.classes.entry(name.to_string()).or_default()
        } else if let Some(name) = tag {
            self.tags.entry(name.to_string()).or_default()
        } else {
            &mut self.common
        }
    }
    pub(super) fn candidates(&self, element: &ElementRef, found: &mut Vec<Branch>) {
        found.clear();
        found.extend_from_slice(&self.common);
        let node = element.handle();
        if let Some(name) = &node.name {
            // SVG 等外来元素的标签可以含大写。索引放宽大小写，完整匹配仍区分。
            let tag: &str = &name.local;
            if let Some(list) = self.tags.get(tag) {
                found.extend_from_slice(list);
            } else if tag.bytes().any(|b| b.is_ascii_uppercase()) {
                if let Some(list) = self.tags.get(&tag.to_ascii_lowercase()) {
                    found.extend_from_slice(list);
                }
            }
        }
        if !self.ids.is_empty()
            && let Some(id) = crate::dom::attr(node, "id")
            && let Some(list) = self.ids.get(&id)
        {
            found.extend_from_slice(list);
        }
        if !self.classes.is_empty()
            && let Some(classes) = crate::dom::attr(node, "class")
        {
            for class in classes.split_ascii_whitespace() {
                if let Some(list) = self.classes.get(class) {
                    found.extend_from_slice(list);
                }
            }
        }
        found.sort_unstable();
        found.dedup();
    }
}
