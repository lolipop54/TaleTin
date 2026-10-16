// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
// TreeSink uses the public html5ever interface. The arena owns all nodes so disposal
// clears edges before dropping nodes; deeply nested input cannot recurse during Drop.
use html5ever::{
    Attribute, QualName,
    interface::tree_builder::{ElementFlags, NodeOrText, QuirksMode, TreeSink},
    tendril::StrTendril,
};
use std::{
    borrow::Cow,
    cell::RefCell,
    rc::{Rc, Weak},
};
pub type Handle = Rc<Node>;
pub struct Node {
    optimized: bool,
    pub id: usize,
    pub name: Option<QualName>,
    pub text: RefCell<String>,
    pub comment: bool,
    pub attrs: RefCell<Vec<Attribute>>,
    pub children: RefCell<Vec<Handle>>,
    parent: RefCell<Weak<Node>>,
    pub template: Option<Handle>,
    integration: bool,
}
pub struct Dom {
    optimized: bool,
    keep_doctype: bool,
    pub nodes: RefCell<Vec<Handle>>,
    pub doctypes: RefCell<std::collections::HashMap<usize, (String, String, String)>>,
    pub document: Handle,
}
impl Dom {
    pub fn new() -> Self {
        Self::with_options(false)
    }
    pub fn with_options(optimized: bool) -> Self {
        let document = Self::node(
            0,
            None,
            String::new(),
            false,
            vec![],
            None,
            false,
            optimized,
        );
        Self {
            optimized,
            keep_doctype: false,
            nodes: RefCell::new(vec![document.clone()]),
            doctypes: RefCell::new(std::collections::HashMap::new()),
            document,
        }
    }
    pub fn for_original() -> Self {
        let mut dom = Self::with_options(true);
        dom.keep_doctype = true;
        dom
    }
    fn node(
        id: usize,
        name: Option<QualName>,
        text: String,
        comment: bool,
        attrs: Vec<Attribute>,
        template: Option<Handle>,
        integration: bool,
        optimized: bool,
    ) -> Handle {
        Rc::new(Node {
            optimized,
            id,
            name,
            text: RefCell::new(text),
            comment,
            attrs: RefCell::new(attrs),
            children: RefCell::new(vec![]),
            parent: RefCell::new(Weak::new()),
            template,
            integration,
        })
    }
    fn alloc(
        &self,
        name: Option<QualName>,
        text: String,
        comment: bool,
        attrs: Vec<Attribute>,
        template: Option<Handle>,
        integration: bool,
    ) -> Handle {
        let node = Self::node(
            self.nodes.borrow().len(),
            name,
            text,
            comment,
            attrs,
            template,
            integration,
            self.optimized,
        );
        self.nodes.borrow_mut().push(node.clone());
        node
    }
    fn insert(&self, parent: &Handle, child: NodeOrText<Handle>, before: Option<&Handle>) {
        let at = before
            .and_then(|b| {
                parent
                    .children
                    .borrow()
                    .iter()
                    .position(|n| Rc::ptr_eq(n, b))
            })
            .unwrap_or(parent.children.borrow().len());
        let child = match child {
            NodeOrText::AppendNode(n) => n,
            NodeOrText::AppendText(t) => {
                if at > 0 {
                    let previous = parent.children.borrow()[at - 1].clone();
                    if previous.name.is_none() && !previous.comment && previous.id != 0 {
                        previous.text.borrow_mut().push_str(&t);
                        return;
                    }
                }
                self.alloc(None, t.to_string(), false, vec![], None, false)
            }
        };
        self.remove_from_parent(&child);
        *child.parent.borrow_mut() = Rc::downgrade(parent);
        let at = before
            .and_then(|b| {
                parent
                    .children
                    .borrow()
                    .iter()
                    .position(|n| Rc::ptr_eq(n, b))
            })
            .unwrap_or(parent.children.borrow().len());
        parent.children.borrow_mut().insert(at, child);
    }
}
impl Drop for Dom {
    fn drop(&mut self) {
        for node in self.nodes.get_mut().iter() {
            node.children.borrow_mut().clear();
        }
    }
}
impl TreeSink for Dom {
    type Handle = Handle;
    type Output = Self;
    type ElemName<'a> = &'a QualName;
    fn finish(self) -> Self {
        self
    }
    fn parse_error(&self, _: Cow<'static, str>) {}
    fn get_document(&self) -> Handle {
        self.document.clone()
    }
    fn elem_name<'a>(&'a self, target: &'a Handle) -> &'a QualName {
        target.name.as_ref().unwrap()
    }
    fn create_element(&self, name: QualName, attrs: Vec<Attribute>, flags: ElementFlags) -> Handle {
        let template = flags
            .template
            .then(|| self.alloc(None, String::new(), false, vec![], None, false));
        self.alloc(
            Some(name),
            String::new(),
            false,
            attrs,
            template,
            flags.mathml_annotation_xml_integration_point,
        )
    }
    fn create_comment(&self, text: StrTendril) -> Handle {
        self.alloc(None, text.to_string(), true, vec![], None, false)
    }
    fn create_pi(&self, _: StrTendril, text: StrTendril) -> Handle {
        self.create_comment(text)
    }
    fn append(&self, parent: &Handle, child: NodeOrText<Handle>) {
        self.insert(parent, child, None);
    }
    fn append_based_on_parent_node(
        &self,
        element: &Handle,
        previous: &Handle,
        child: NodeOrText<Handle>,
    ) {
        if element.parent.borrow().upgrade().is_some() {
            self.append_before_sibling(element, child);
        } else {
            self.append(previous, child);
        }
    }
    fn append_doctype_to_document(&self, name: StrTendril, public: StrTendril, system: StrTendril) {
        if self.keep_doctype {
            let node = self.alloc(None, String::new(), true, vec![], None, false);
            self.doctypes.borrow_mut().insert(
                node.id,
                (name.to_string(), public.to_string(), system.to_string()),
            );
            self.append(&self.document, NodeOrText::AppendNode(node));
        }
    }
    fn get_template_contents(&self, target: &Handle) -> Handle {
        target.template.as_ref().unwrap().clone()
    }
    fn same_node(&self, a: &Handle, b: &Handle) -> bool {
        Rc::ptr_eq(a, b)
    }
    fn set_quirks_mode(&self, _: QuirksMode) {}
    fn append_before_sibling(&self, sibling: &Handle, child: NodeOrText<Handle>) {
        let parent = sibling.parent.borrow().upgrade();
        if let Some(parent) = parent {
            self.insert(&parent, child, Some(sibling));
        }
    }
    fn add_attrs_if_missing(&self, target: &Handle, attrs: Vec<Attribute>) {
        let mut existing = target.attrs.borrow_mut();
        for attr in attrs {
            if !existing.iter().any(|a| a.name == attr.name) {
                existing.push(attr);
            }
        }
    }
    fn remove_from_parent(&self, target: &Handle) {
        if let Some(parent) = target.parent.borrow_mut().upgrade() {
            parent
                .children
                .borrow_mut()
                .retain(|n| !Rc::ptr_eq(n, target));
        }
        *target.parent.borrow_mut() = Weak::new();
    }
    fn reparent_children(&self, node: &Handle, parent: &Handle) {
        let children = node.children.take();
        for child in children {
            self.append(parent, NodeOrText::AppendNode(child));
        }
    }
    fn is_mathml_annotation_xml_integration_point(&self, handle: &Handle) -> bool {
        handle.integration
    }
}
pub fn tag(node: &Handle) -> &str {
    node.name.as_ref().map(|n| n.local.as_ref()).unwrap_or("")
}
pub fn attr(node: &Handle, key: &str) -> Option<String> {
    node.attrs
        .borrow()
        .iter()
        .find(|a| {
            if node.optimized {
                // HTML epub:type may be a whole local name; SVG can instead
                // carry a namespace prefix. Preserve both representations.
                return if let Some(prefix) = &a.name.prefix {
                    key.split_once(':')
                        .is_some_and(|(p, local)| &**prefix == p && &*a.name.local == local)
                } else {
                    &*a.name.local == key
                };
            }
            let name = a
                .name
                .prefix
                .as_ref()
                .map(|p| format!("{}:{}", p, a.name.local))
                .unwrap_or(a.name.local.to_string());
            name == key
        })
        .map(|a| a.value.to_string())
}
