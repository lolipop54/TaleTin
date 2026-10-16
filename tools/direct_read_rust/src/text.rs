// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use encoding_rs::{Decoder, Encoding};

pub fn encoding(id: u32) -> &'static Encoding {
    match id {
        1 => encoding_rs::UTF_16LE,
        2 => encoding_rs::UTF_16BE,
        4 => encoding_rs::GB18030,
        5 => encoding_rs::GBK,
        6 => encoding_rs::BIG5,
        7 => encoding_rs::SHIFT_JIS,
        8 => encoding_rs::EUC_KR,
        10 => encoding_rs::WINDOWS_1252,
        _ => encoding_rs::UTF_8,
    }
}

// ISO-8859-1 is deliberately not mapped to WHATWG windows-1252: existing
// Android imports preserve U+0080..U+009F for these byte values.
pub fn decode(bytes: &[u8], id: u32) -> String {
    if id == 9 {
        bytes.iter().map(|&b| b as char).collect()
    } else {
        encoding(id)
            .decode_without_bom_handling(bytes)
            .0
            .into_owned()
    }
}

pub struct TextDecoder {
    pub output: Vec<u8>,
    decoder: Decoder,
    latin1: bool,
}
impl TextDecoder {
    pub fn new(id: u32) -> Self {
        Self {
            output: Vec::new(),
            decoder: encoding(id).new_decoder_without_bom_handling(),
            latin1: id == 9,
        }
    }
    pub fn feed(&mut self, bytes: &[u8], finish: bool) -> Vec<u8> {
        if self.latin1 {
            return decode(bytes, 9).into_bytes();
        }
        let capacity = self.decoder.max_utf8_buffer_length(bytes.len()).unwrap();
        let mut text = String::with_capacity(capacity);
        let (_, read, _) = self.decoder.decode_to_string(bytes, &mut text, finish);
        debug_assert_eq!(read, bytes.len());
        text.into_bytes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gb18030_four_bytes_and_chunk_edges() {
        let bytes = [0x84, 0x31, 0x95, 0x33, 0xd6, 0xd0, 0x94, 0x39, 0xfc, 0x36];
        assert_eq!(decode(&bytes, 4), "\u{feff}中😀");
        for chunk in 1..=bytes.len() {
            let mut decoder = TextDecoder::new(4);
            let mut output = Vec::new();
            for part in bytes.chunks(chunk) {
                output.extend(decoder.feed(part, false));
            }
            output.extend(decoder.feed(&[], true));
            assert_eq!(String::from_utf8(output).unwrap(), "\u{feff}中😀");
        }
    }
    #[test]
    fn latin1_is_not_windows1252() {
        assert_eq!(decode(&[0x80, 0xff], 9), "\u{80}ÿ");
        assert_eq!(decode(&[0x80], 10), "€");
    }
}
