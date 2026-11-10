use super::*;
pub(super) fn units(s: &str) -> usize {
    s.encode_utf16().count()
}
/// 把追加时的原始文字位置换算成裁剪后的块内位置（UTF-16）。
///
/// 裁剪只去掉各 run 首尾空白；图片位置落在 run 边界上，按保留下来的
/// 前面所有 run 长度相加即可，与硬换行位置同一套口径。
pub(super) fn block_offset(
    offset: usize,
    raw_lengths: &[usize],
    kept_index: &[Option<usize>],
    kept_leading: &[usize],
    runs: &[Run],
) -> usize {
    let mut raw_cursor = 0usize;
    let mut kept_cursor = 0usize;
    for (i, raw_length) in raw_lengths.iter().enumerate() {
        let (kept_length, leading) = match kept_index.get(i).copied().flatten() {
            Some(index) => (units(&runs[index].text), kept_leading[index]),
            None => (0, *raw_length),
        };
        if offset <= raw_cursor + raw_length {
            let within = offset.saturating_sub(raw_cursor + leading);
            return kept_cursor + within.min(kept_length);
        }
        raw_cursor += raw_length;
        kept_cursor += kept_length;
    }
    kept_cursor
}
/// 合并前这段文字会分成几个非空块（用于还原旧的位置权重和块号）。
pub(super) fn nonempty_chunks(offsets: &[usize], text_length: usize) -> usize {
    let mut chunks = 0;
    let mut start = 0;
    for offset in offsets {
        if *offset > start {
            chunks += 1;
        }
        start = *offset;
    }
    if text_length > start {
        chunks += 1;
    }
    chunks
}
/// 裁掉片段首尾空白，返回（裁剪后的文字、头部裁掉的 UTF-16 长度）。
pub(super) fn trim_run(text: &str) -> (String, usize) {
    let start = text.trim_start_matches(|c| c == ' ' || c == '\n');
    if start.len() == text.len() && !text.ends_with(' ') && !text.ends_with('\n') {
        return (text.to_owned(), 0);
    }
    let leading = units(text) - units(start);
    (
        start.trim_end_matches(|c| c == ' ' || c == '\n').to_owned(),
        leading,
    )
}

/// 带 `<br>` 换行的 run：只裁头部，保留尾部空格。
///
/// `line_break` 在 run 末尾追加一个空格并记下它的位置；`flush` 之后会把这个
/// 空格替换成换行符。若这里也裁尾，位置就落到文字之外，换行会静默丢失。
pub(super) fn trim_run_keep_break(text: &str) -> (String, usize) {
    let start = text.trim_start_matches(|c| c == ' ' || c == '\n');
    let leading = units(text) - units(start);
    (start.to_owned(), leading)
}
/// 同样式才合并成同一个 run：与旧版一致，只看加粗和斜体。
///
/// 上下标、颜色、字号都不参与合并：先按旧规则拼接与裁剪，最后在最终文字上切分，
/// 段末空格才不会被单独裁掉，块长度保持不变。
pub(super) fn same_style(a: &Style, b: &Style) -> bool {
    // 只看加粗／斜体：颜色、字号只影响显示，不能改变 run 边界与首尾裁剪
    a.bold == b.bold && a.italic == b.italic
}
/// 在最终文字上切出上下标、颜色与字号片段（文字不变，只改变 run 的分布）。
pub(super) fn split_inline_styles(
    runs: Vec<Run>,
    starts: &[usize],
    marks: &[StyleMark],
    kept_index: &[Option<usize>],
    kept_leading: &[usize],
) -> Vec<Run> {
    if marks.is_empty() || runs.is_empty() {
        return runs;
    }
    // 换算成块内绝对范围（UTF-16 下标）
    let mut ranges: Vec<(
        usize,
        usize,
        u8,
        Option<u32>,
        f64,
        Option<bool>,
        Option<bool>,
        u8,
        Option<String>,
        bool,
    )> = vec![];
    for mark in marks {
        let Some(index) = kept_index.get(mark.run).copied().flatten() else {
            continue;
        };
        let run_start = starts[index];
        let run_length = units(&runs[index].text);
        // 样式从被裁掉的首空白开始时，保留它与正文相交的部分。
        let from = mark.offset.saturating_sub(kept_leading[index]);
        if from >= run_length {
            continue;
        }
        let to = (mark.offset + mark.length)
            .saturating_sub(kept_leading[index])
            .min(run_length);
        if to <= from {
            continue;
        }
        ranges.push((
            run_start + from,
            run_start + to,
            mark.script,
            mark.color,
            mark.size,
            mark.css_bold,
            mark.css_italic,
            mark.deco,
            mark.link.clone(),
            mark.footnote,
        ));
    }
    if ranges.is_empty() {
        return runs;
    }
    ranges.sort_by_key(|range| range.0);

    let mut result: Vec<Run> = vec![];
    for (i, run) in runs.into_iter().enumerate() {
        let begin = starts[i];
        let text_units: Vec<u16> = run.text.encode_utf16().collect();
        let end = begin + text_units.len();
        let slice = |from: usize, to: usize| -> String {
            String::from_utf16_lossy(&text_units[from - begin..to - begin])
        };
        let mut push = |text: String,
                        script: u8,
                        color: Option<u32>,
                        size: f64,
                        css_bold: Option<bool>,
                        css_italic: Option<bool>,
                        deco: u8,
                        link: Option<String>,
                        footnote: bool,
                        base: Style,
                        result: &mut Vec<Run>| {
            if text.is_empty() {
                return;
            }
            let mut style = base;
            style.script = script;
            style.color = color;
            style.size = size;
            style.bold = css_bold.unwrap_or(base.bold);
            style.italic = css_italic.unwrap_or(base.italic);
            style.deco = deco;
            // 相邻同样式的片段合并，避免一段文字被切成很多小 run
            if let Some(previous) = result.last_mut() {
                if previous.style.bold == style.bold
                    && previous.style.italic == style.italic
                    && previous.style.script == style.script
                    && previous.style.color == style.color
                    && previous.style.size == style.size
                    && previous.style.deco == style.deco
                    && previous.link == link
                    && previous.footnote == footnote
                {
                    previous.text.push_str(&text);
                    return;
                }
            }
            result.push(Run {
                text,
                style,
                link,
                footnote,
            });
        };
        let mut cursor = begin;
        for (from, to, script, color, size, css_bold, css_italic, deco, link, footnote) in &ranges {
            if *to <= cursor || *from >= end {
                continue;
            }
            let a = (*from).max(cursor);
            let b = (*to).min(end);
            if a > cursor {
                push(
                    slice(cursor, a),
                    0,
                    None,
                    1.0,
                    None,
                    None,
                    0,
                    None,
                    false,
                    run.style,
                    &mut result,
                );
            }
            if b > a {
                push(
                    slice(a, b),
                    *script,
                    *color,
                    *size,
                    *css_bold,
                    *css_italic,
                    *deco,
                    link.clone(),
                    *footnote,
                    run.style,
                    &mut result,
                );
            }
            cursor = b;
        }
        if cursor < end {
            push(
                slice(cursor, end),
                0,
                None,
                1.0,
                None,
                None,
                0,
                None,
                false,
                run.style,
                &mut result,
            );
        }
    }
    result
}

/// 链接文字是不是脚注编号：`[1]`、`(2)` 或上标数字。
///
/// 不认单个裸数字，避免把目录里的「1」误当成脚注。
/// 同一编号可以套中英文括号；身份判断仍需要链接和上下文。
pub(super) fn note_marker_text(text: &str) -> &str {
    let mut value = text.trim();
    while let (Some(first), Some(last)) = (value.chars().next(), value.chars().last()) {
        if !matches!(
            (first, last),
            ('[', ']') | ('(', ')') | ('（', '）') | ('【', '】')
        ) {
            break;
        }
        value = value[first.len_utf8()..value.len() - last.len_utf8()].trim();
    }
    value
}
pub(super) fn looks_like_note_marker(text: &str) -> bool {
    let value = text.trim();
    let chars: Vec<char> = value.chars().collect();
    if chars.is_empty() || chars.len() > 8 {
        return false;
    }
    let label = note_marker_text(value);
    let bracketed = label != value;
    let mut superscript = 0;
    for c in &chars {
        if matches!(*c, '\u{00b9}' | '\u{00b2}' | '\u{00b3}') {
            superscript += 1;
        } else if ('\u{2070}'..='\u{2079}').contains(c) {
            superscript += 1;
        }
    }
    (bracketed && !label.is_empty() && label.chars().all(|c| c.is_ascii_digit()))
        || chars.iter().all(|c| matches!(*c, '①'..='⑳' | '㉑'..='㉟' | '㊱'..='㊿' | '❶'..='❿' | '➀'..='➉' | '⓵'..='⓾'))
        || (superscript > 0 && superscript == chars.len())
}

/// EPUB2 常把裸数字链接放在 sup/small 中；只凭“是数字”会误伤目录。
/// 必须同时有上标祖先，并在遇到实际段落前停止查找。
pub(super) fn superscript_note_marker(node: &Handle) -> bool {
    let text = text_of(node);
    let value = text.trim();
    if !looks_like_note_marker(value)
        && (value.is_empty() || value.len() > 4 || !value.chars().all(|c| c.is_ascii_digit()))
    {
        return false;
    }
    // EPUB2 的另一种写法是 a 包着 sup，而不是 sup 包着 a。
    if find(node, "sup").is_some_and(|sup| text_of(&sup).trim() == value) {
        return true;
    }
    let mut parent = node.parent.borrow().upgrade();
    while let Some(element) = parent {
        match tag(&element) {
            "sup" => return true,
            "a" | "span" | "small" | "font" | "b" | "strong" | "i" | "em" => {}
            _ => return false,
        }
        parent = element.parent.borrow().upgrade();
    }
    false
}
