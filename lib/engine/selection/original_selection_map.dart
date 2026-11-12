/// 原书 DOM 点 ↔ 标准正文 Locator 的双向换算（实现计划 S4）。
///
/// 原书正文由 WebView 排版，选中哪里只能从 DOM 出发：视口点 → DOM 文本点 →
/// 块 + 块内偏移；反过来，保存下来的 Locator → DOM 文本点 → 视口矩形。
/// 两个方向都走净化正文对照表（[LocatorDomMap]），所以：
/// - 重复句靠**块序**区分，不靠搜相同文字猜位置；
/// - 内联标签（`span`/`em`）按同一段文字合并，偏移仍然对得上原文；
/// - 空白折叠、空白被裁掉的首尾字符按同一套规则换算回原节点。
///
/// 这个类只做换算，不决定「选中要不要保存」；WebView 不可用、节点已被替换、
/// 落在图片或空白上时一律返回 null，由调用方按「没有选中」处理。
library;

import 'package:characters/characters.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../normalization/locator_mapper.dart';
import '../parsers/epub/locator_dom_point.dart';
import 'initial_text_range.dart';

/// 原书页面上的一点在 DOM 里的位置：`{path, offset}`
typedef DomPoint = Map<String, Object?>;

class OriginalSelectionMap {
  const OriginalSelectionMap({required this.map, required this.content});

  /// 章节的 DOM ↔ 块偏移对照表（由 [OriginalLayoutController.positionMap] 提供）
  final LocatorDomMap map;

  /// 这一章的标准化正文（与 [map] 的块表一一对应）
  final ChapterContent content;

  /// 生成 Locator 的换算器（与原书对照表同一份）
  LocatorMapper get mapper => map.mapper;

  /// DOM 点 → 正文位置；认不出这个点（图片、空白、框架节点）时返回 null。
  Locator? locatorAt(DomPoint point) {
    try {
      return map.locatorOf(point);
    } on Object {
      // 节点是纯空白、块表里没有这一段文字、偏移越界：都当没选中
      return null;
    }
  }

  /// 正文位置 → DOM 点；[end] 为 true 时取范围的结束端（贴在上一段末尾）。
  DomPoint? pointOf(Locator locator, {bool end = false}) {
    try {
      return map.point(locator, end: end);
    } on Object {
      // 这一块在原书里没有对应文字（例如只有装饰的块）时放弃
      return null;
    }
  }

  /// 用实际命中的 DOM 字符在原文里找起选范围。
  Future<({Locator start, Locator end})?> initialRangeAt(DomPoint point) async {
    final locator = locatorAt(point);
    if (locator == null) return null;
    final block = _blockOf(locator.blockId);
    if (block == null) return null;
    final text = blockTextOf(block);
    final hit = locator.utf16Offset;
    // 内联标签边缘的空格有时只留在原书网页里。把它们当作词边界，
    // 避免将网页上隔开的文字拼成一个词。
    var lower = 0, upper = text.length;
    void splitAt(int offset) {
      if (offset > lower && offset <= hit) lower = offset;
      if (offset > hit && offset < upper) upper = offset;
    }

    for (final run in map.textRuns(block.id)) {
      if (run.end < lower || run.start > upper) continue;
      if (run.text.trimLeft().length < run.text.length) splitAt(run.start);
      if (run.text.trimRight().length < run.text.length) splitAt(run.end);
    }
    final range = await initialTextRange(
      text,
      hit,
      within: (start: lower, end: upper),
    );
    if (range == null) return null;
    return (
      start: mapper.at(block, range.start),
      end: mapper.at(block, range.end),
    );
  }

  /// 章首（[atEnd] 为 false）或章末（true）的 DOM 点。
  ///
  /// 跨章的笔记要按章裁开：前章取到章末、后章从章首起，和简化模式的矩形裁剪
  /// 是同一条规则。整章没有文字时返回 null。
  DomPoint? chapterEdgePoint({required bool atEnd}) {
    final texts = [
      for (final block in content.blocks)
        if (blockTextOf(block).isNotEmpty) block,
    ];
    if (texts.isEmpty) return null;
    final block = atEnd ? texts.last : texts.first;
    final offset = atEnd ? blockTextOf(block).length : 0;
    return pointOf(mapper.at(block, offset), end: atEnd);
  }

  /// 某个位置往后一个字的 Locator：把范围终点夹到「本页最后一个字之后」用它。
  Locator? nextChar(Locator locator) {
    final block = _blockOf(locator.blockId);
    if (block == null) return null;
    final text = blockTextOf(block);
    final offset = locator.utf16Offset;
    if (offset >= text.length) return locator;
    final character = CharacterRange.at(text, offset, offset + 1);
    return mapper.at(
      block,
      character.stringBeforeLength + character.current.length,
    );
  }

  /// 拖动端点用 DOM 插入点定位。
  Locator? pointLocatorAt(DomPoint point) => locatorAt(point);

  /// 块表查询：[content] 的块跟原书文字一一对应（建表时已核对）
  ContentBlock? _blockOf(String blockId) {
    for (final block in content.blocks) {
      if (block.id == blockId) return block;
    }
    return null;
  }
}
