// Copyright (c) 2026 GT Reader contributors. GPL-3.0-only, see LICENSE.
//! 统一 CSS：有序来源、语法解析、选择器匹配、层叠、继承、变量和值类型。
//!
//! 生产转换只走这一条路径；旧 `styles.rs` 的规则匹配在 S8 删除。

pub mod engine;
pub mod parser;
pub mod selector;
pub mod style;
pub mod value;

pub use engine::{Engine, StyleCache};
pub use style::{Computed, Props};

mod cascade;
mod inheritance;
mod layers;
mod presentation;
pub(crate) mod presentation_table;
mod properties;
pub mod publication;
#[cfg(test)]
mod publication_tests;
pub mod resources;
mod rule_set;
mod shorthand;
mod tree;
mod variables;

mod conditions;
mod font_faces;
pub mod program;
