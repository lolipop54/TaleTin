/// 一个来源元素在排版里到底是块级还是行内：全项目只在这里判断一次。
///
/// 为什么需要这个文件：Rust 已经把 CSS `display` 和标签默认算进元素样式，
/// 但旧缓存的样式表可能没有 `display`；而 `<code>` 的来源角色同时服务块级
/// `<pre>` 和行内 `<code>`，只看角色会判错。以前显示树和行内盒子各写一套
/// 兜底，同一个元素会得到两个答案（显示树里是块级，行内盒子那里是行内），
/// 现在统一走这里。
library;

import '../../domain/models/display_source_index.dart';
import '../styles/computed_style.dart';
import '../styles/property_parsers.dart';
import '../styles/style_box_value.dart';
import '../styles/tag_defaults.dart';

/// 元素最终的 `display`。
///
/// 顺序固定：
/// 1. 元素样式里写了 `display`（作者样式表、行内样式或标签默认已经算进去）→ 用它；
/// 2. 样式里没有时再查标签默认表（旧缓存的样式表可能没带 `display`）；
/// 3. 都没有才按来源角色兜底：容器角色是块级，行内角色是行内。
///
/// 第 3 步只是旧缓存的保险；新转换出来的 `<code>` 会在标签默认表里拿到
/// `display:inline`，不会走到角色兜底。
DisplaySpec displayOf(DisplayElement element, ComputedStyle style) {
  final computed = style.block.display;
  if (computed != null) return computed;
  final declared = TagDefaults.forTag(element.tag)?['display'];
  if (declared != null) {
    final parsed = StyleParser.display(declared);
    if (parsed != null) return parsed;
  }
  return element.isContainer ? DisplaySpec.block : DisplaySpec.inline;
}

/// 行内元素：它参与行内流，可以有自己的背景／边框，但不独占一行。
bool isInlineDisplay(DisplaySpec display) =>
    display == DisplaySpec.inline || display == DisplaySpec.inlineBlock;

/// 块级元素：独占一行。`none` 不产生盒子，所以既不算行内也不算块级；
/// 调用方拿到 `none` 时按「不显示这个元素」处理。
bool isBlockDisplay(DisplaySpec display) =>
    display != DisplaySpec.inline &&
    display != DisplaySpec.inlineBlock &&
    display != DisplaySpec.none;
