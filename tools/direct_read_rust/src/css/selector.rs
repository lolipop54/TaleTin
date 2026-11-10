// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
//! 把 `selectors` 接在现有 `html5ever` DOM 上。
//!
//! `selectors::Element` 不能直接实现给外部类型 `Rc<Node>`（孤儿规则），所以用一层
//! `ElementRef` 包装；它只引用原节点，不复制 DOM，也不改变正文转换的遍历顺序。

use std::{borrow::Borrow, fmt, rc::Rc};

use cssparser::{CowRcStr, ParseError, ToCss, serialize_identifier, serialize_string};
use html5ever::{LocalName, Namespace};
use precomputed_hash::PrecomputedHash;
use selectors::{
    Element, OpaqueElement,
    attr::{AttrSelectorOperation, CaseSensitivity, NamespaceConstraint},
    context::MatchingContext,
    matching::ElementSelectorFlags,
    parser::{
        NonTSPseudoClass, ParseRelative, Parser as SelectorParser, PseudoElement, SelectorImpl,
        SelectorList, SelectorParseErrorKind,
    },
};

use crate::dom::{Handle, attr, tag};

/// `selectors` 要求选择器里的标识符实现 `ToCss`；`string_cache::Atom` 没有这个实现。
#[derive(Clone, Debug, Default, Eq, Hash, PartialEq)]
pub struct Atom(pub LocalName);

impl From<&str> for Atom {
    fn from(value: &str) -> Self {
        Self(LocalName::from(value))
    }
}

impl Borrow<str> for Atom {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl ToCss for Atom {
    fn to_css<W: fmt::Write>(&self, dest: &mut W) -> fmt::Result {
        serialize_identifier(&self.0, dest)
    }
}

impl PrecomputedHash for Atom {
    fn precomputed_hash(&self) -> u32 {
        self.0.precomputed_hash()
    }
}

#[derive(Clone, Debug, Default, Eq, Hash, PartialEq)]
pub struct Ns(pub Namespace);

impl From<&str> for Ns {
    fn from(value: &str) -> Self {
        Self(Namespace::from(value))
    }
}

impl Borrow<str> for Ns {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl ToCss for Ns {
    fn to_css<W: fmt::Write>(&self, dest: &mut W) -> fmt::Result {
        serialize_identifier(&self.0, dest)
    }
}

impl PrecomputedHash for Ns {
    fn precomputed_hash(&self) -> u32 {
        self.0.precomputed_hash()
    }
}

#[derive(Clone, Debug, Default, Eq, Hash, PartialEq)]
pub struct AttrVal(pub String);

impl From<&str> for AttrVal {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

impl ToCss for AttrVal {
    fn to_css<W: fmt::Write>(&self, dest: &mut W) -> fmt::Result {
        serialize_string(&self.0, dest)
    }
}

impl AsRef<str> for AttrVal {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

/// 交互伪类不在正式书内样式里求值：遇到 `:hover` 等整条规则跳过，
/// 与当前生产行为一致，也不偷偷承诺浏览器状态。
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NeverPseudoClass {}

impl ToCss for NeverPseudoClass {
    fn to_css<W: fmt::Write>(&self, _: &mut W) -> fmt::Result {
        match *self {}
    }
}

impl NonTSPseudoClass for NeverPseudoClass {
    fn is_active_or_hover(&self) -> bool {
        match *self {}
    }

    fn is_user_action_state(&self) -> bool {
        match *self {}
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NeverPseudoElement {}

impl ToCss for NeverPseudoElement {
    fn to_css<W: fmt::Write>(&self, _: &mut W) -> fmt::Result {
        match *self {}
    }
}

impl PseudoElement for NeverPseudoElement {}

#[derive(Clone, Debug, Default)]
pub struct CssSelectorImpl;

impl SelectorImpl for CssSelectorImpl {
    type ExtraMatchingData<'a> = ();
    type AttrValue = AttrVal;
    type Identifier = Atom;
    type LocalName = Atom;
    type NamespaceUrl = Ns;
    type NamespacePrefix = Ns;
    type BorrowedNamespaceUrl = str;
    type BorrowedLocalName = str;
    type NonTSPseudoClass = NeverPseudoClass;
    type PseudoElement = NeverPseudoElement;
}

pub struct CssSelectorParser;

impl<'i> SelectorParser<'i> for CssSelectorParser {
    type Impl = CssSelectorImpl;
    type Error = SelectorParseErrorKind;

    fn parse_is_and_where(&self) -> bool {
        true
    }

    fn parse_nth_child_of(&self) -> bool {
        true
    }
}

/// 把一个元素包成选择器可匹配的引用；节点本身仍是原 DOM 的 `Rc<Node>`。
#[derive(Clone)]
pub struct ElementRef(pub Handle);

impl fmt::Debug for ElementRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "<{}#{}>", crate::dom::tag(&self.0), self.0.id)
    }
}

impl ElementRef {
    pub fn new(handle: Handle) -> Self {
        Self(handle)
    }

    pub fn handle(&self) -> &Handle {
        &self.0
    }
}

fn attr_value(node: &Handle, target: &LocalName) -> Option<String> {
    node.attrs
        .borrow()
        .iter()
        .find(|a| a.name.local == *target)
        .map(|a| a.value.to_string())
}

fn element_children(node: &Handle) -> Vec<Handle> {
    node.children
        .borrow()
        .iter()
        .filter(|child| child.name.is_some())
        .cloned()
        .collect()
}

impl Element for ElementRef {
    type Impl = CssSelectorImpl;

    fn opaque(&self) -> OpaqueElement {
        // 必须指向节点本身，不能指向临时的 ElementRef；否则结构伪类的缓存会错位。
        OpaqueElement::new(self.0.as_ref())
    }

    fn parent_element(&self) -> Option<Self> {
        let parent = self.0.parent.borrow().upgrade()?;
        parent.name.as_ref()?;
        Some(Self(parent))
    }

    fn parent_node_is_shadow_root(&self) -> bool {
        false
    }

    fn containing_shadow_host(&self) -> Option<Self> {
        None
    }

    fn is_pseudo_element(&self) -> bool {
        false
    }

    fn prev_sibling_element(&self) -> Option<Self> {
        let parent = self.0.parent.borrow().upgrade()?;
        let children = parent.children.borrow();
        let index = children.iter().position(|node| Rc::ptr_eq(node, &self.0))?;
        children[..index]
            .iter()
            .rev()
            .find(|node| node.name.is_some())
            .cloned()
            .map(Self)
    }

    fn next_sibling_element(&self) -> Option<Self> {
        let parent = self.0.parent.borrow().upgrade()?;
        let children = parent.children.borrow();
        let index = children.iter().position(|node| Rc::ptr_eq(node, &self.0))?;
        children[index + 1..]
            .iter()
            .find(|node| node.name.is_some())
            .cloned()
            .map(Self)
    }

    fn first_element_child(&self) -> Option<Self> {
        element_children(&self.0).into_iter().next().map(Self)
    }

    fn is_html_element_in_html_document(&self) -> bool {
        self.0
            .name
            .as_ref()
            .is_some_and(|name| &*name.ns == "http://www.w3.org/1999/xhtml")
    }

    fn has_local_name(&self, local_name: &str) -> bool {
        self.0
            .name
            .as_ref()
            .is_some_and(|name| &*name.local == local_name)
    }

    fn has_namespace(&self, ns: &str) -> bool {
        self.0.name.as_ref().is_some_and(|name| &*name.ns == ns)
    }

    fn is_same_type(&self, other: &Self) -> bool {
        self.0.name == other.0.name
    }

    fn attr_matches(
        &self,
        ns: &NamespaceConstraint<&<Self::Impl as SelectorImpl>::NamespaceUrl>,
        local_name: &<Self::Impl as SelectorImpl>::LocalName,
        operation: &AttrSelectorOperation<&<Self::Impl as SelectorImpl>::AttrValue>,
    ) -> bool {
        let Some(value) = attr_value(&self.0, &local_name.0) else {
            return false;
        };
        // HTML 属性默认没有命名空间；`has_attr_in_no_namespace` 会用空命名空间来问。
        // 这里只拒绝真正带非空命名空间的属性选择器，避免误用元素命名空间比较。
        if let NamespaceConstraint::Specific(url) = ns {
            if !url.0.is_empty() {
                return false;
            }
        }
        operation.eval_str(&value)
    }

    fn match_non_ts_pseudo_class(
        &self,
        _: &<Self::Impl as SelectorImpl>::NonTSPseudoClass,
        _: &mut MatchingContext<Self::Impl>,
    ) -> bool {
        false
    }

    fn match_pseudo_element(
        &self,
        _: &<Self::Impl as SelectorImpl>::PseudoElement,
        _: &mut MatchingContext<Self::Impl>,
    ) -> bool {
        false
    }

    fn is_link(&self) -> bool {
        tag(&self.0).eq_ignore_ascii_case("a") && attr(&self.0, "href").is_some()
    }

    fn is_html_slot_element(&self) -> bool {
        tag(&self.0).eq_ignore_ascii_case("slot")
    }

    fn has_id(
        &self,
        id: &<Self::Impl as SelectorImpl>::Identifier,
        case_sensitivity: CaseSensitivity,
    ) -> bool {
        attr(&self.0, "id")
            .is_some_and(|value| case_sensitivity.eq(value.as_bytes(), (&*id.0).as_bytes()))
    }

    fn has_class(
        &self,
        name: &<Self::Impl as SelectorImpl>::Identifier,
        case_sensitivity: CaseSensitivity,
    ) -> bool {
        attr(&self.0, "class").is_some_and(|value| {
            value
                .split_ascii_whitespace()
                .any(|class| case_sensitivity.eq(class.as_bytes(), (&*name.0).as_bytes()))
        })
    }

    fn has_custom_state(&self, _: &<Self::Impl as SelectorImpl>::Identifier) -> bool {
        false
    }

    fn imported_part(
        &self,
        _: &<Self::Impl as SelectorImpl>::Identifier,
    ) -> Option<<Self::Impl as SelectorImpl>::Identifier> {
        None
    }

    fn is_part(&self, _: &<Self::Impl as SelectorImpl>::Identifier) -> bool {
        false
    }

    fn is_empty(&self) -> bool {
        self.0
            .children
            .borrow()
            .iter()
            .all(|child| match &child.name {
                Some(_) => false,
                None => child.text.borrow().is_empty(),
            })
    }

    fn is_root(&self) -> bool {
        match self.0.parent.borrow().upgrade() {
            Some(parent) => parent.name.is_none() && parent.id == 0,
            None => false,
        }
    }

    fn apply_selector_flags(&self, _: ElementSelectorFlags) {}

    fn add_element_unique_hashes(&self, _: &mut selectors::bloom::BloomFilter) -> bool {
        false
    }
}

pub fn parse_selector_list<'i>(
    input: &mut cssparser::Parser<'i>,
) -> Result<SelectorList<CssSelectorImpl>, ParseError<SelectorParseErrorKind>> {
    SelectorList::parse(&CssSelectorParser, input, ParseRelative::No)
}

pub fn matches_selector_list(
    selectors: &SelectorList<CssSelectorImpl>,
    element: &ElementRef,
) -> Option<u32> {
    let mut caches = selectors::context::SelectorCaches::default();
    let mut context = MatchingContext::new(
        selectors::context::MatchingMode::Normal,
        None,
        &mut caches,
        selectors::context::QuirksMode::NoQuirks,
        selectors::context::NeedsSelectorFlags::No,
        selectors::context::MatchingForInvalidation::No,
    );
    let mut best: Option<u32> = None;
    for selector in selectors.slice() {
        if selectors::matching::matches_selector(selector, 0, None, element, &mut context) {
            let specificity = selector.specificity();
            best = Some(best.map_or(specificity, |current| current.max(specificity)));
        }
    }
    best
}

#[allow(dead_code)]
fn _keep_cow(_: CowRcStr<'_>) {}
