//! 层叠候选保留到回退完成；revert-layer 不能退成 inherit/unset。
#[derive(Clone, Debug)]
pub(super) struct Candidate {
    pub value: String,
    pub important: bool,
    pub inline: bool,
    pub author: bool,
    pub layer: Vec<u32>,
    pub specificity: u32,
    pub order: u32,
    pub index: u32,
}

impl Candidate {
    fn key(&self) -> (bool, bool, bool, Vec<u32>, u32, u32, u32) {
        // 每层未分层的声明排在其所有子层之后；important 的层顺序反转。
        let mut layer = self.layer.clone();
        layer.push(u32::MAX);
        if self.important {
            layer.iter_mut().for_each(|v| *v = u32::MAX - *v);
        }
        (
            self.important,
            self.author,
            self.inline,
            layer,
            self.specificity,
            self.order,
            self.index,
        )
    }
}

pub(super) fn winner(values: &[Candidate]) -> Option<&Candidate> {
    let mut sorted: Vec<_> = values.iter().collect();
    sorted.sort_by_cached_key(|c| c.key());
    while let Some(candidate) = sorted.pop() {
        match candidate.value.as_str() {
            "revert" => sorted.retain(|c| c.author != candidate.author),
            "revert-layer" => sorted.retain(|c| {
                c.author != candidate.author || c.inline != candidate.inline ||
                    // 同层较早声明也被撤回；子层有独立优先级，仍可接手。
                    (c.layer != candidate.layer && (c.important || !candidate.important || {
                        let mut normal = candidate.clone();
                        normal.important = false;
                        c.key().3 < normal.key().3
                    }))
            }),
            _ => return Some(candidate),
        }
    }
    None
}
