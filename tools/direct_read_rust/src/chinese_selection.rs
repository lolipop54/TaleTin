// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use jieba_rs::Jieba;
use std::{slice, sync::OnceLock};

fn word_at(text: &str, hit: usize) -> Option<(usize, usize)> {
    static JIEBA: OnceLock<Jieba> = OnceLock::new();
    let jieba = JIEBA.get_or_init(Jieba::new);
    let mut start = 0;
    // Disable HMM guesses so unknown text can fall back to the touched character.
    for token in jieba.cut(text, false) {
        let end = start + token.word.encode_utf16().count();
        if hit < end {
            return (token.word.chars().nth(1).is_some() && jieba.has_word(token.word))
                .then_some((start, end));
        }
        start = end;
    }
    None
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_chinese_word_at(
    text: *const u16,
    length: usize,
    hit: usize,
    bounds: *mut u32,
) -> u32 {
    if hit >= length {
        return 0;
    }
    let text = String::from_utf16_lossy(unsafe { slice::from_raw_parts(text, length) });
    let Some((start, end)) = word_at(&text, hit) else {
        return 0;
    };
    unsafe {
        bounds.write(start as u32);
        bounds.add(1).write(end as u32);
    }
    1
}

#[cfg(test)]
mod tests {
    use super::word_at;

    #[test]
    fn selects_dictionary_word_from_any_character_using_utf16() {
        for hit in 2..5 {
            assert_eq!(word_at("😀心理学很有趣。", hit), Some((2, 5)));
        }
    }

    #[test]
    fn unknown_characters_do_not_form_a_word() {
        assert_eq!(word_at("𠮷龘靐", 2), None);
    }
}
