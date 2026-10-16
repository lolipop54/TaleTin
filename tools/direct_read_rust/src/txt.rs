// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
pub struct Scanner {
    pub output: Vec<u8>,
    encoding: u32,
    offset: u64,
    start: u64,
    pending: Vec<u8>,
    after_cr: bool,
    carry: Option<u8>,
    pub hash: Option<crate::hash::Hash>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn packets_keep_bom_indent_emoji_ranges_and_reuse() {
        let source = "\u{feff}第一章\r\n　😀 a\u{feff}  \n尾";
        for encoding in [0, 1, 2] {
            let bytes = if encoding == 0 { source.as_bytes().to_vec() } else {
                source.encode_utf16().flat_map(|u| if encoding == 1 { u.to_le_bytes() } else { u.to_be_bytes() }).collect()
            };
            for chunk in [1, 2, 3, 7, 65536] {
                let mut scanner = Scanner::new(encoding, 0);
                let mut packet = Vec::new();
                for part in bytes.chunks(chunk) { packet.extend(scanner.feed(part, false)); }
                packet.extend(scanner.feed(&[], true));
                let mut at = 0;
                let mut rows = Vec::new();
                let mut reused = 0;
                while at < packet.len() {
                    let start = u64::from_le_bytes(packet[at..at+8].try_into().unwrap());
                    let end = u64::from_le_bytes(packet[at+8..at+16].try_into().unwrap());
                    let raw_size = u32::from_le_bytes(packet[at+16..at+20].try_into().unwrap()) as usize;
                    let size = u32::from_le_bytes(packet[at+20..at+24].try_into().unwrap());
                    let units = u32::from_le_bytes(packet[at+24..at+28].try_into().unwrap()); at += 28;
                    let raw = String::from_utf8(packet[at..at+raw_size].to_vec()).unwrap(); at += raw_size;
                    let text = if size == u32::MAX { reused += 1; raw.clone() } else {
                        let text = String::from_utf8(packet[at..at+size as usize].to_vec()).unwrap(); at += size as usize; text
                    };
                    rows.push((start, end, raw, text, units));
                }
                let bounds = if encoding == 0 { [(0,12),(14,28),(29,32)] } else { [(0,8),(12,28),(30,32)] };
                assert_eq!(rows, vec![
                    (bounds[0].0,bounds[0].1,"第一章".into(),"第一章".into(),3),
                    (bounds[1].0,bounds[1].1,"　😀 a\u{feff}  ".into(),"😀 a\u{feff}".into(),5),
                    (bounds[2].0,bounds[2].1,"尾".into(),"尾".into(),1)]);
                assert_eq!(reused, 2);
            }
        }
    }
}
pub fn txt_space(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\n' | '\r' | '\u{c}' | '\u{b}' | '\u{85}' | '\u{a0}' | '\u{3000}'
    )
}
/// Count the exact UTF-16 output as it is written, without another full scan.
fn normalize_count(text: &str) -> (String, u32) {
    let mut out = String::with_capacity(text.len());
    let mut pending = false;
    let mut units = 0;
    for c in text.chars() {
        if txt_space(c) {
            pending = !out.is_empty();
            continue;
        }
        if pending {
            out.push(' ');
            units += 1;
            pending = false;
        }
        out.push(c);
        units += c.len_utf16() as u32;
    }
    (out, units)
}
impl Scanner {
    pub fn new(encoding: u32, offset: u64) -> Self {
        Self {
            output: Vec::new(),
            encoding,
            offset,
            start: offset,
            pending: Vec::new(),
            after_cr: false,
            carry: None,
            hash: None,
        }
    }
    fn line(&mut self, end: u64, out: &mut Vec<u8>) {
        // Encoding 3 remains available for the old boundary-only benchmark.
        let raw = match self.encoding {
            1 | 2 => {
                let codes = self.pending.chunks_exact(2).map(|v| {
                    if self.encoding == 1 {
                        u16::from_le_bytes([v[0], v[1]])
                    } else {
                        u16::from_be_bytes([v[0], v[1]])
                    }
                });
                char::decode_utf16(codes)
                    .map(|c| c.unwrap_or('\u{fffd}'))
                    .collect::<String>()
            }
            3 => String::new(),
            4..=10 => crate::text::decode(&self.pending, self.encoding),
            _ => String::from_utf8_lossy(&self.pending).into_owned(),
        };
        let raw = if self.start == 0 {
            raw.strip_prefix('\u{feff}').unwrap_or(&raw)
        } else {
            &raw
        };
        let (normalized, units) = normalize_count(raw);
        // This is a private packet consumed by the matching Dart native package.
        // The sentinel reuses the raw string without losing chapter indentation.
        let reuse = !raw.is_empty() && normalized == raw;
        out.extend_from_slice(&self.start.to_le_bytes());
        out.extend_from_slice(&end.to_le_bytes());
        out.extend_from_slice(&(raw.len() as u32).to_le_bytes());
        out.extend_from_slice(&(if reuse { u32::MAX } else { normalized.len() as u32 }).to_le_bytes());
        out.extend_from_slice(&units.to_le_bytes());
        out.extend_from_slice(raw.as_bytes());
        if !reuse { out.extend_from_slice(normalized.as_bytes()); }
        self.pending.clear();
    }
    fn unit(&mut self, bytes: &[u8], code: u16, out: &mut Vec<u8>) {
        if self.after_cr {
            self.after_cr = false;
            if code == 10 {
                self.offset += bytes.len() as u64;
                self.start = self.offset;
                return;
            }
        }
        if code == 10 || code == 13 {
            self.line(self.offset, out);
            self.offset += bytes.len() as u64;
            self.start = self.offset;
            self.after_cr = code == 13;
        } else {
            if self.encoding != 3 {
                self.pending.extend_from_slice(bytes);
            }
            self.offset += bytes.len() as u64;
        }
    }
    pub fn feed(&mut self, bytes: &[u8], finish: bool) -> Vec<u8> {
        if let Some(hash) = &mut self.hash {
            hash.feed(bytes, false);
        }
        let mut out = Vec::with_capacity(bytes.len());
        if self.encoding == 1 || self.encoding == 2 {
            let mut at = 0;
            if let Some(first) = self.carry.take() {
                if let Some(&second) = bytes.first() {
                    let pair = [first, second];
                    self.unit(&pair, self.code(pair), &mut out);
                    at = 1;
                } else {
                    self.carry = Some(first);
                }
            }
            while at + 1 < bytes.len() {
                let pair = [bytes[at], bytes[at + 1]];
                self.unit(&pair, self.code(pair), &mut out);
                at += 2;
            }
            if at < bytes.len() {
                self.carry = Some(bytes[at]);
            }
        } else {
            let mut at = 0;
            // A CR at the end of the previous chunk may swallow the first LF.
            if self.after_cr && !bytes.is_empty() {
                self.unit(&bytes[..1], bytes[0] as u16, &mut out);
                at = 1;
            }
            while at < bytes.len() {
                let end = memchr::memchr2(10, 13, &bytes[at..])
                    .map(|n| at + n).unwrap_or(bytes.len());
                if end > at {
                    self.after_cr = false;
                    if self.encoding != 3 { self.pending.extend_from_slice(&bytes[at..end]); }
                    self.offset += (end - at) as u64;
                }
                at = end;
                if at < bytes.len() {
                    self.unit(&bytes[at..at+1], bytes[at] as u16, &mut out);
                    at += 1;
                }
            }
        }
        // No synthetic final blank line after a terminal newline; odd UTF-16 byte is ignored.
        if finish && self.start < self.offset {
            self.line(self.offset, &mut out);
        }
        out
    }
    fn code(&self, pair: [u8; 2]) -> u16 {
        if self.encoding == 1 {
            u16::from_le_bytes(pair)
        } else {
            u16::from_be_bytes(pair)
        }
    }
}
