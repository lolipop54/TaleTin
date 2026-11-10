//! 层名字和首次出现顺序跨来源/导入共享；嵌套层保留各级次序。
use cssparser::{Parser, Token};
use std::collections::HashMap;

#[derive(Default)]
pub(super) struct Layers {
    ids: HashMap<Vec<String>, Vec<u32>>,
    counts: HashMap<Vec<String>, u32>,
    anonymous: u32,
}
impl Layers {
    pub fn name(&mut self, parent: &[String], name: &str) -> Option<Vec<String>> {
        let mut path = parent.to_vec();
        if name.trim().is_empty() {
            self.anonymous += 1;
            path.push(format!("#anonymous{}", self.anonymous));
        } else {
            let mut input = Parser::new(name);
            loop {
                path.push(input.expect_ident().ok()?.to_string());
                if input.is_exhausted() {
                    break;
                }
                input.expect_delim('.').ok()?;
            }
        }
        for len in 1..=path.len() {
            let key = path[..len].to_vec();
            if self.ids.contains_key(&key) {
                continue;
            }
            let parent = key[..len - 1].to_vec();
            let next = self.counts.entry(parent.clone()).or_default();
            let mut rank = self.ids.get(&parent).cloned().unwrap_or_default();
            rank.push(*next);
            *next += 1;
            self.ids.insert(key, rank);
        }
        Some(path)
    }
    pub fn rank(&self, name: &[String]) -> Vec<u32> {
        self.ids.get(name).cloned().unwrap_or_default()
    }
}

/// @import 的 layer / layer(name) 从后续媒体条件中分离。
pub(super) fn import_layer(tail: &str) -> Option<(Option<String>, String)> {
    let mut input = Parser::new(tail);
    let start = input.state();
    let layer = match input.next().ok().cloned() {
        Some(Token::Ident(name)) if name.eq_ignore_ascii_case("layer") => Some(String::new()),
        Some(Token::Function(name)) if name.eq_ignore_ascii_case("layer") => Some(
            input
                .parse_nested_block::<_, _, ()>(|p| {
                    let start = p.position();
                    while p.next().is_ok() {}
                    Ok(p.slice_from(start).trim().to_owned())
                })
                .ok()?,
        ),
        _ => {
            input.reset(&start);
            None
        }
    };
    let position = input.position();
    while input.next().is_ok() {}
    Some((layer, input.slice_from(position).trim().to_owned()))
}
