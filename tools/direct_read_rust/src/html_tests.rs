use super::*;
#[cfg(test)]
mod unified_css_tests {
    use super::*;
    use serde_json::json;

    fn convert(html: &str, css: &str) -> Value {
        let document = Html::new(html.as_bytes());
        document.convert(
            json!({
                "images": {},
                "links": {},
                "displaySource": true,
                "cssSources": [{"path": "OEBPS/ch.xhtml", "text": css, "inline": true}],
                "cssFiles": {},
            }),
            0,
        )
    }

    #[test]
    fn legacy_style_table_still_feeds_old_path() {
        let document = Html::new(b"<body><p>a</p></body>");
        let result = document.convert(
            json!({
                "images": {},
                "links": {},
                "styles": {
                    "v": 1,
                    "rules": [
                        {"sel": [{"t": "p"}], "spec": 1, "order": 0, "p": {"a": 2}}
                    ]
                }
            }),
            0,
        );
        assert_eq!(result["blocks"][0]["align"], "center");
    }

    #[test]
    fn author_css_reaches_block_and_runs() {
        let result = convert(
            r#"<body><p class="lead">普通 <b>粗</b> <span style="color: #00ff00">绿</span></p></body>"#,
            r#"
            p { color: #ff0000; font-size: 1.5em; margin: 1em 0; text-indent: 0; }
            .lead { text-align: center; }
            b { font-weight: normal; }
            "#,
        );
        let blocks = result["blocks"].as_array().unwrap();
        assert_eq!(blocks.len(), 1);
        let block = &blocks[0];
        assert_eq!(block["align"], "center");
        assert_eq!(block["noIndent"], true);
        let runs = block["runs"].as_array().unwrap();
        let text = runs
            .iter()
            .map(|run| {
                run["text"]
                    .as_str()
                    .unwrap_or_else(|| run.as_str().unwrap())
            })
            .collect::<String>();
        // 样式边界裁掉两侧空格，这是旧转换器的既有正文口径；新 CSS 不能改它。
        assert_eq!(text, "普通粗绿");
        // b 被 CSS 改成 normal：语义标签的粗体要被明确覆盖，最终没有 bold run。
        assert!(text.contains("粗"));
        assert!(
            !runs
                .iter()
                .any(|run| run.get("bold") == Some(&Value::Bool(true)))
        );
        // 行内样式颜色进入 run；字号倍数继承 1.5。
        let green = runs
            .iter()
            .find(|run| run["text"] == "绿")
            .expect("green run");
        assert_eq!(green["c"].as_u64(), Some(0xff00ff00));
        assert_eq!(green["fs"], 1.5);
    }

    #[test]
    fn important_beats_inline_normal_but_not_inline_important() {
        let result = convert(
            r#"<body><p style="color: blue">a</p><p style="color: blue">b</p></body>"#,
            r#"p { color: red !important; } p + p { color: green !important; }"#,
        );
        let blocks = result["blocks"].as_array().unwrap();
        let first = blocks[0]["runs"][0]["c"].as_u64().unwrap();
        let second = blocks[1]["runs"][0]["c"].as_u64().unwrap();
        assert_eq!(first, 0xffff0000);
        assert_eq!(second, 0xff008000);
    }

    #[test]
    fn variables_are_scoped_to_ancestors() {
        let result = convert(
            r#"<body><div style="--x: #ff0000"><p>a</p></div><p>b</p></body>"#,
            r#"p { color: var(--x, #0000ff); }"#,
        );
        let blocks = result["blocks"].as_array().unwrap();
        assert_eq!(blocks[0]["runs"][0]["c"].as_u64(), Some(0xffff0000));
        assert_eq!(blocks[1]["runs"][0]["c"].as_u64(), Some(0xff0000ff));
    }
}
