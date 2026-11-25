//! 可重建的书内规则树。缓存正文只保存源书摘要和章节路径，应用重开后重新绑定书库。
use super::conditions::Environment;
use super::parser::Stylesheet;
use super::rule_set::RuleSet;
use super::tree::{ConditionChecks, References, Sheet, activate};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, LazyLock, Mutex};

pub(super) struct Active {
    pub sheet: Stylesheet,
    pub index: RuleSet,
}
impl Active {
    pub fn new(sheet: Stylesheet, indexed: bool) -> Self {
        let index = if indexed {
            #[cfg(test)]
            let start = std::time::Instant::now();
            let index = RuleSet::new(&sheet);
            #[cfg(test)]
            super::publication_tests::note_index(start.elapsed().as_nanos());
            index
        } else {
            RuleSet::default()
        };
        Self { sheet, index }
    }
}
#[derive(Deserialize)]
struct Book {
    version: u32,
    digest: String,
    sheets: HashMap<String, Sheet>,
    chapters: HashMap<String, References>,
    #[serde(default, rename = "openingChapters")]
    opening_chapters: std::collections::HashSet<String>,
    #[serde(skip)]
    active: Mutex<VecDeque<(Key, Arc<Active>)>>,
}
#[derive(PartialEq)]
struct Key {
    refs: References,
    indexed: bool,
    checks: ConditionChecks,
}

#[derive(Clone, PartialEq)]
struct Binding {
    path: String,
    bytes: u64,
    modified: Option<std::time::SystemTime>,
}

#[derive(Default)]
struct Books {
    // 只保留很小的绑定路径。释放旧书的树后，仍在屏幕上的旧章节可按需重载。
    paths: HashMap<String, Binding>,
    loaded: VecDeque<(String, Arc<Book>)>,
}
static BOOKS: LazyLock<Mutex<Books>> = LazyLock::new(Default::default);

fn open(digest: &str, binding: Option<&str>) -> Result<Arc<Book>, String> {
    let requested = if let Some(path) = binding {
        // 备份恢复可能换了目录或重写同名文件；读过的旧副本不能替代新文件的校验。
        let stat = std::fs::metadata(path).map_err(|e| e.to_string())?;
        Some(Binding {
            path: path.to_owned(),
            bytes: stat.len(),
            modified: stat.modified().ok(),
        })
    } else {
        None
    };
    let mut books = BOOKS.lock().unwrap();
    let known = books.paths.get(digest);
    let same = requested.as_ref().is_none_or(|r| Some(r) == known);
    let file = requested
        .as_ref()
        .or(known)
        .ok_or("当前阅读会话尚未绑定样式树")?
        .clone();
    if same && let Some(i) = books.loaded.iter().position(|(key, _)| key == digest) {
        let entry = books.loaded.remove(i).unwrap();
        let book = entry.1.clone();
        books.loaded.push_back(entry);
        return Ok(book);
    }
    drop(books);
    let data = std::fs::read(&file.path).map_err(|e| e.to_string())?;
    let book: Book = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
    if book.version != 1 || book.digest != digest {
        return Err("源书或样式树版本不一致".into());
    }
    let book = Arc::new(book);
    let mut books = BOOKS.lock().unwrap();
    if books.paths.get(digest) == Some(&file) {
        if let Some((_, prior)) = books.loaded.iter().find(|(key, _)| key == digest) {
            return Ok(prior.clone());
        }
    } else {
        books.loaded.retain(|(key, _)| key != digest);
        books.paths.insert(digest.to_owned(), file);
    }
    if books.loaded.len() >= 4 {
        books.loaded.pop_front();
    }
    books.loaded.push_back((digest.to_owned(), book.clone()));
    Ok(book)
}

pub fn command(input: &Value) -> Value {
    if let (Some(text), Some(path)) = (input["text"].as_str(), input["path"].as_str()) {
        let (sheet, imports) = Sheet::parse(path, text);
        return json!({"sheet": sheet, "imports": imports});
    }
    match (input["digest"].as_str(), input["file"].as_str()) {
        (Some(digest), Some(file)) => match open(digest, Some(file)) {
            Ok(_) => json!({"ok": true}),
            Err(error) => json!({"error": error}),
        },
        _ => json!({"error": "样式树命令缺少参数"}),
    }
}

pub(crate) fn repeated_opening(digest: &str, path: &str) -> bool {
    open(digest, None).is_ok_and(|book| book.opening_chapters.contains(path))
}

pub(super) fn for_chapter(
    digest: &str,
    path: &str,
    env: &Environment,
    indexed: bool,
) -> Result<Arc<Active>, String> {
    let book = open(digest, None)?;
    let refs = book.chapters.get(path).ok_or("样式树缺少章节")?;
    {
        let active = book.active.lock().unwrap();
        if let Some((_, set)) = active.iter().find(|(key, _)| {
            key.indexed == indexed
                && key.refs == *refs
                && key
                    .checks
                    .iter()
                    .all(|(kind, query, old)| env.matches(kind, query) == *old)
        }) {
            #[cfg(test)]
            super::publication_tests::note_reuse();
            return Ok(set.clone());
        }
    }
    let (sheet, checks) = activate(&book.sheets, refs, env)?;
    let set = Arc::new(Active::new(sheet, indexed));
    let mut active = book.active.lock().unwrap();
    if active.len() >= 16 {
        active.pop_front();
    }
    active.push_back((
        Key {
            refs: refs.clone(),
            indexed,
            checks,
        },
        set.clone(),
    ));
    Ok(set)
}
