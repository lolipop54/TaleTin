// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use std::collections::HashMap;
use std::borrow::Cow;

#[derive(Default)]
struct Pattern {
    next: HashMap<u8, usize>,
    values: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unchanged_text_is_borrowed_without_removing_existing_hyphens() {
        let mut dictionary = English::new(b"UTF-8\n");
        let source = "中文😀 existing\u{ad}word";
        let (result, positions) = dictionary.display(source);
        assert!(matches!(result, Cow::Borrowed(_)));
        assert_eq!(result, source);
        assert!(positions.is_empty());
    }
}
/// Liang pattern matching for the bundled English dictionary. Application callers
/// only hyphenate ASCII letter runs; no user-supplied dictionaries are accepted.
pub struct English {
    trie: Vec<Pattern>,
    cache: HashMap<String, Vec<usize>>,
}
impl English {
    pub fn new(bytes: &[u8]) -> Self {
        let mut this = Self {
            trie: vec![Pattern::default()],
            cache: HashMap::new(),
        };
        for line in String::from_utf8_lossy(bytes).lines().skip(1) {
            let line = line.trim();
            if line.is_empty() || line.starts_with('%') || line.as_bytes()[0].is_ascii_uppercase() {
                continue;
            }
            let mut key = Vec::new();
            let mut values = vec![0];
            for c in line.bytes() {
                if c.is_ascii_digit() {
                    *values.last_mut().unwrap() = c - b'0';
                } else {
                    key.push(c);
                    values.push(0);
                }
            }
            let mut at = 0;
            for c in key {
                at = if let Some(&child) = this.trie[at].next.get(&c) {
                    child
                } else {
                    let child = this.trie.len();
                    this.trie.push(Pattern::default());
                    this.trie[at].next.insert(c, child);
                    child
                };
            }
            this.trie[at].values = values;
        }
        this
    }
    fn breaks(&mut self, word: &str) -> &[usize] {
        let key = word.to_ascii_lowercase();
        self.cache.entry(key.clone()).or_insert_with(|| {
            let text = format!(".{key}.");
            let bytes = text.as_bytes();
            let mut scores = vec![0; bytes.len() + 1];
            for start in 0..bytes.len() {
                let mut at = 0;
                for &c in &bytes[start..] {
                    let Some(&child) = self.trie[at].next.get(&c) else {
                        break;
                    };
                    at = child;
                    for (i, &value) in self.trie[at].values.iter().enumerate() {
                        scores[start + i] = scores[start + i].max(value);
                    }
                }
            }
            (2..=word.len().saturating_sub(3))
                .filter(|&i| scores[i + 1] & 1 != 0)
                .collect()
        })
    }
    /// Returns displayed text and insertion positions in UTF-16, including earlier
    /// inserted soft hyphens, exactly as the DOM-to-original mapping expects.
    pub fn display<'a>(&mut self, text: &'a str) -> (Cow<'a, str>, Vec<usize>) {
        let bytes = text.as_bytes();
        let mut split = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            if !bytes[at].is_ascii_alphabetic() {
                at += 1;
                continue;
            }
            let start = at;
            while at < bytes.len() && bytes[at].is_ascii_alphabetic() {
                at += 1;
            }
            if at - start >= 5 {
                split.extend(self.breaks(&text[start..at]).iter().map(|i| start + i));
            }
        }
        if self.cache.len() > 1024 { self.cache.clear(); }
        if split.is_empty() { return (Cow::Borrowed(text), Vec::new()); }
        let mut result = String::with_capacity(text.len() + split.len() * 2);
        let mut positions = Vec::new();
        let mut units = 0;
        let mut next = 0;
        for (byte, c) in text.char_indices() {
            if split.get(next) == Some(&byte) {
                positions.push(units);
                result.push('\u{ad}');
                units += 1;
                next += 1;
            }
            result.push(c);
            units += c.len_utf16();
        }
        (Cow::Owned(result), positions)
    }
}
