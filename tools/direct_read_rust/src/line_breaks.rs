use std::slice;

/// UAX #14 返回 UTF-8 字节边界；Flutter 的文字选择和测宽使用 UTF-16。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_line_breaks(
    text: *const u16,
    length: usize,
    breaks: *mut u32,
) -> usize {
    if length == 0 {
        return 0;
    }
    let text = String::from_utf16_lossy(unsafe { slice::from_raw_parts(text, length) });
    let output = unsafe { slice::from_raw_parts_mut(breaks, length) };
    let (mut last, mut units, mut count) = (0, 0, 0);
    for (end, _) in unicode_linebreak::linebreaks(&text) {
        units += text[last..end].encode_utf16().count();
        output[count] = units as u32;
        count += 1;
        last = end;
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn breaks_keep_surrogate_pairs_and_non_breaking_space_together() {
        let text: Vec<u16> = "甲𠀀乙 A\u{a0}B".encode_utf16().collect();
        let mut output = vec![0; text.len()];
        let count = unsafe { gt_line_breaks(text.as_ptr(), text.len(), output.as_mut_ptr()) };
        assert_eq!(&output[..count], &[1, 3, 5, 8]);
    }
}
