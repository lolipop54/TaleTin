//! CSS URL 必须在声明所属文件中解析，不能等到图片绘制时再相对章节猜路径。
use cssparser::{Parser, Token};
use std::collections::HashSet;

pub fn rewrite(value: &str, source: &str) -> (String, HashSet<String>) {
    let mut parser = Parser::new(value);
    let mut paths = HashSet::new();
    let text = tokens(&mut parser, source, &mut paths);
    (text, paths)
}

fn tokens(input: &mut Parser, source: &str, paths: &mut HashSet<String>) -> String {
    let mut out = String::new();
    loop {
        let start = input.position();
        let Ok(token) = input.next_including_whitespace_and_comments().cloned() else {
            break;
        };
        match token {
            Token::UnquotedUrl(url) => out.push_str(&url_text(&url, source, paths)),
            Token::Function(name) if name.eq_ignore_ascii_case("url") => {
                let url: Result<_, cssparser::ParseError<()>> =
                    input.parse_nested_block(|nested| {
                        nested.expect_string_cloned().map_err(|e| e.into())
                    });
                if let Ok(url) = url {
                    out.push_str(&url_text(&url, source, paths));
                } else {
                    out.push_str("url(\"\")");
                }
            }
            Token::Function(_)
            | Token::ParenthesisBlock
            | Token::SquareBracketBlock
            | Token::CurlyBracketBlock => {
                let opening = input.slice_from(start).to_owned();
                let closing = match token {
                    Token::SquareBracketBlock => "]",
                    Token::CurlyBracketBlock => "}",
                    _ => ")",
                };
                let body: Result<String, cssparser::ParseError<()>> =
                    input.parse_nested_block(|nested| Ok(tokens(nested, source, paths)));
                out.push_str(&opening);
                if let Ok(body) = body {
                    out.push_str(&body);
                }
                out.push_str(closing);
            }
            _ => out.push_str(input.slice_from(start)),
        }
    }
    out
}

fn url_text(raw: &str, source: &str, paths: &mut HashSet<String>) -> String {
    let Some(path) = local_path(raw, source) else {
        return "url(\"\")".to_owned();
    };
    paths.insert(path.clone());
    format!("url({})", serde_json::to_string(&path).unwrap())
}

pub(super) fn local_path(raw: &str, source: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty()
        || raw.starts_with('#')
        || raw.starts_with("//")
        || raw.contains(':')
        || raw.contains('\\')
    {
        return None;
    }
    let raw = raw.split(['?', '#']).next()?;
    let mut bytes = Vec::new();
    let mut chars = raw.as_bytes().iter().copied();
    while let Some(c) = chars.next() {
        if c == b'%' {
            let a = (chars.next()? as char).to_digit(16)?;
            let b = (chars.next()? as char).to_digit(16)?;
            bytes.push((a * 16 + b) as u8);
        } else {
            bytes.push(c);
        }
    }
    let decoded = String::from_utf8(bytes).ok()?;
    if decoded.contains([':', '\\', '\0']) || decoded.starts_with("//") {
        return None;
    }
    let (base, target) = if let Some(path) = decoded.strip_prefix('/') {
        ("", path)
    } else {
        (
            source.rsplit_once('/').map_or("", |v| v.0),
            decoded.as_str(),
        )
    };
    let mut parts: Vec<&str> = base.split('/').filter(|p| !p.is_empty()).collect();
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            p => parts.push(p),
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(format!("res/{}", parts.join("/")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_case_and_file_origin_and_rejects_external_paths() {
        let (s, paths) = rewrite(
            "--bg:url('../Images/Vol%20Title.PNG');background:var(--bg)",
            "OEBPS/CSS/main.css",
        );
        assert!(s.contains("res/OEBPS/Images/Vol Title.PNG"));
        assert!(paths.contains("res/OEBPS/Images/Vol Title.PNG"));
        for raw in [
            "https://example.com/a.png",
            "file:///a.png",
            "../../../a.png",
            "%2e%2e/%2e%2e/a.png",
        ] {
            assert!(local_path(raw, "OEBPS/a.css").is_none());
        }
    }
}
