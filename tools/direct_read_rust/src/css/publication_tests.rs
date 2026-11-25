use super::{conditions::Environment, publication, resources};
use crate::html::Html;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};

static BOOK: AtomicUsize = AtomicUsize::new(0);
// 仅专项诊断从每个测试线程取阶段计时，正式阅读不会逐规则读时钟。
thread_local! {
    static STAGES: std::cell::Cell<[u64; 4]> = const { std::cell::Cell::new([0; 4]) };
}
pub(super) fn note_compile(ns: u128) {
    let mut totals = STAGES.get();
    totals[0] += 1;
    totals[1] += ns as u64;
    STAGES.set(totals);
}
pub(super) fn note_index(ns: u128) {
    let mut totals = STAGES.get();
    totals[2] += ns as u64;
    STAGES.set(totals);
}
pub(super) fn note_reuse() {
    let mut totals = STAGES.get();
    totals[3] += 1;
    STAGES.set(totals);
}

// 经过正式编译、写盘、重新读取、节点映射和环境重算入口，对照完整章节数据。
fn compare(html: &[u8], path: &str, files: &HashMap<String, String>, targets: &[&str]) -> Value {
    let doc = Html::new(html);
    let digest = format!(
        "css-test-{}-{}",
        std::process::id(),
        BOOK.fetch_add(1, Ordering::Relaxed)
    );
    let file = std::env::temp_dir().join(format!("{digest}.json"));
    let mut sheets = serde_json::Map::new();
    let mut refs = Vec::new();
    let mut sources = Vec::new();
    let mut compile = |id: &str, path: &str, text: &str| {
        let tree = publication::command(&json!({"path":path,"text":text}));
        sheets.insert(id.into(), tree["sheet"].clone());
    };
    for (id, text) in files {
        compile(id, id, text);
    }
    for (i, tag) in doc.refs()["css"].as_array().unwrap().iter().enumerate() {
        let raw = tag["value"].as_str().unwrap();
        let inline = tag["inline"] == true;
        let (id, base, css) = if inline {
            let id = format!("inline-{i}");
            compile(&id, path, raw);
            (id, path, raw.as_ref())
        } else {
            let Some(id) = resources::local_entry(raw, path) else {
                continue;
            };
            let Some((key, text)) = files.get_key_value(&id) else {
                continue;
            };
            (id, key.as_str(), text.as_str())
        };
        let media = tag["media"].as_str().unwrap_or("");
        refs.push(json!([id, media]));
        let text = if media.is_empty() {
            css.to_owned()
        } else {
            format!("@media {media} {{{css}}}")
        };
        sources.push(json!({"path":base,"text":text,"inline":inline}));
    }
    std::fs::write(
        &file,
        serde_json::to_vec(&json!({"version":1,"digest":digest,
        "sheets":sheets,"chapters":{path:refs}}))
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        publication::command(&json!({"digest":digest,"file":file}))["ok"],
        true
    );
    let mut samples = Vec::new();
    for dark in [false, true] {
        for target in targets {
            let env = json!({"dark":dark,"width":420,"fontSize":20});
            let base = json!({"displaySource":true,"documentPath":path,"unifiedCss":true,
                "cssEnvironment":env,"cssTraceElement":target,"cssDiagnostics":true, "cssCompareHits":true});
            let mut expected = None;
            let mut expected_dynamic = None;
            for arm in ["legacy", "tree", "indexed"] {
                let mut meta = base.clone();
                if arm == "legacy" {
                    meta["cssSources"] = json!(sources);
                    meta["cssFiles"] = json!(files);
                } else {
                    meta["cssBook"] = json!(digest);
                    meta["cssFullScan"] = json!(arm == "tree");
                }
                let start = std::time::Instant::now();
                STAGES.set([0; 4]);
                let mut result = doc.convert(meta, 0);
                let micros = start.elapsed().as_micros();
                assert!(result["cssError"].is_null(), "{arm} {result}");
                let [compiled, compile_ns, index_ns, reused] = STAGES.get();
                samples.push(
                    json!({"arm":arm,"dark":dark,"us":micros,"counts":result["cssDiagnostics"],
                        "compiled":compiled,"compileUs":compile_ns/1000,"indexUs":index_ns/1000,"reused":reused}),
                );
                result.as_object_mut().unwrap().remove("cssDiagnostics");
                if let Some(program) = result["displaySource"]
                    .as_object_mut()
                    .unwrap()
                    .remove("css")
                {
                    let actual = super::program::evaluate(
                        &json!({"styleProgram":program,"cssEnvironment":{"dark":!dark,"width":780,"fontSize":28}}),
                    );
                    if let Some(ref expected) = expected_dynamic {
                        assert_eq!(&actual, expected, "条件重算 {arm}");
                    } else {
                        expected_dynamic = Some(actual);
                    }
                } else {
                    assert!(expected_dynamic.is_none());
                }
                if let Some(ref expected) = expected {
                    assert_eq!(&result, expected, "{arm} {path} {target}");
                } else {
                    expected = Some(result);
                }
            }
        }
    }
    let env = Environment::default();
    let first = publication::for_chapter(&digest, path, &env, true).unwrap();
    let next = publication::for_chapter(
        &digest,
        path,
        &Environment {
            width: env.width + 1.,
            ..env
        },
        true,
    )
    .unwrap();
    assert!(std::sync::Arc::ptr_eq(&first, &next));
    std::fs::remove_file(file).unwrap();
    json!(samples)
}

#[test]
fn persisted_rules_match_legacy_for_each_branch_and_environment() {
    let files = HashMap::from([
        (
            "css/base.css".into(),
            r#"@import 'nested.css'; @layer base, notes;
          @layer base {p {color: blue} } .note {--ink:#664422}
          #unused, .unused, figure, td, th, cite { color:green }"#
                .into(),
        ),
        (
            "css/nested.css".into(),
            r#"@import 'base.css'; @font-face{font-family: Test;src:url('../fonts/a.ttf')}
          .note > p strong, #winner {color:var(--ink); background-image:url('../images/bg.png')}
          p + p {margin: 3px} p:nth-child(2) {padding:2px} :not(.muted) {font-style:italic}"#
                .into(),
        ),
    ]);
    let input = br#"<link rel="stylesheet" href="../css/base.css"><style>
      @supports (color:red){ @media (prefers-color-scheme:dark){.note{--ink:silver}
      .note > p > strong {color:gold !important}}}
      @layer notes {p {color:red;color:invalid}}
      .note > p strong:is(.notice,#winner) {font-weight:900}
      </style><link rel="stylesheet" href="../css/base.css" media="(min-width: 600px)">
      <aside class="note"><p><strong class="notice notice" id="winner">A</strong>
      <span><strong id="deep">B</strong></span></p><p id="second">C</p></aside>"#;
    let samples = compare(input, "text/c.xhtml", &files, &["winner", "deep", "second"]);
    let rows = samples.as_array().unwrap();
    assert!(rows[2]["counts"]["attempts"].as_u64() < rows[0]["counts"]["attempts"].as_u64());
}

#[test]
#[ignore = "从三本本地 EPUB 提取样章后单独运行"]
fn real_chapter_style_comparison() {
    let input = std::env::var("GT_CSS_BENCH_FIXTURES").expect("缺少真实样章文件");
    let fixtures: Value = serde_json::from_slice(&std::fs::read(input).unwrap()).unwrap();
    for chapter in fixtures.as_array().unwrap() {
        let files = serde_json::from_value(chapter["files"].clone()).unwrap();
        let samples = compare(
            chapter["html"].as_str().unwrap().as_bytes(),
            chapter["path"].as_str().unwrap(),
            &files,
            &[""],
        );
        println!(
            "CSS_SAMPLE {}",
            json!({"book":chapter["book"],"chapter":chapter["path"],"samples":samples})
        );
    }
}
