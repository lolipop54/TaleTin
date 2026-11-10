use cssparser::{Parser, Token};
use serde_json::{Value, json};

/// Use the CSS tokenizer for both declarations and font faces so quotes,
/// escaped names and commas have the same meaning on either side.
pub fn families(value: &str) -> Option<Vec<String>> {
    Parser::new(value)
        .parse_comma_separated(|input| -> Result<String, cssparser::ParseError<()>> {
            match input.next()?.clone() {
                Token::QuotedString(name) => Ok(name.to_string()),
                Token::Ident(name) => {
                    let mut name = name.to_string();
                    while !input.is_exhausted() {
                        name.push(' ');
                        name.push_str(input.expect_ident()?);
                    }
                    Ok(name)
                }
                _ => Err(cssparser::ParseError::unexpected_token()),
            }
        })
        .ok()
}

pub fn declaration(body: &str, path: &str) -> Option<Value> {
    let declarations = super::parser::parse_inline_declarations(body);
    let get = |name| {
        declarations
            .iter()
            .rev()
            .find(|d| d.name == name)
            .map(|d| d.value.as_str())
    };
    let names = families(get("font-family")?)?;
    if names.len() != 1 || names[0].is_empty() {
        return None;
    }
    let sources: Vec<_> = super::value::split_top_level(get("src")?, ',')
        .into_iter()
        .filter_map(|candidate| {
            let url = Parser::new(&candidate).expect_url().ok()?;
            super::resources::local_path(&url, path)
        })
        .collect();
    if sources.is_empty() {
        return None;
    }
    Some(json!({
        "family": names[0],
        "sources": sources,
        "weight": get("font-weight").unwrap_or("normal"),
        "style": get("font-style").unwrap_or("normal"),
    }))
}
