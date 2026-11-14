/// 脚注气泡：点正文里的脚注标记（如 `[1]`）时不直接跳页，先展示脚注内容，
/// 右下角再提供“跳转”去原书位置。
///
/// 文字来源是原书章节 HTML 里锚点处的内容；只在点击时读取一次，不改正文。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../engine/layout/chapter_layout.dart';
import '../../../../engine/layout/measured_block.dart';
import '../../../../engine/layout/line_text_geometry.dart';
import '../../../../engine/selection/scroll_selection.dart';
import '../../../../engine/parsers/epub/html_anchor_index.dart';

import '../../../core/theme/reading_theme.dart';
import '../view_models/original_layout_controller.dart';
import '../view_models/reader_session_view_model.dart';
import 'thought_popover.dart';
import 'footnote_markers.dart';

/// 在排版结果里找到某个文字位置对应的链接。
///
/// [locator] 的偏移是标准化正文坐标（不含首行缩进前缀），这里换算成显示坐标
/// 后找所在的 run。返回 null 表示这个位置不是链接。
({String link, bool footnote})? linkAtLocator(
  ChapterLayout layout,
  Locator locator,
) {
  final block = layout.blocks
      .where((b) => b.blockId == locator.blockId)
      .firstOrNull;
  return block == null ? null : linkAtMeasured(block, locator.utf16Offset);
}

/// 同上，直接给测量块（连续滚动模式没有 ChapterLayout）。
({String link, bool footnote})? linkAtMeasured(
  MeasuredBlock block,
  int normalizedOffset,
) {
  if (block.runs.isEmpty) return null;
  final display = normalizedOffset + block.displayPrefixLength;
  var cursor = 0;
  for (final run in block.runs) {
    final end = cursor + run.text.length;
    if (display >= cursor && display < end) {
      // 命中普通正文就直接结束，不能继续回退到段末的脚注链接。
      return run.link == null
          ? null
          : (link: run.link!, footnote: run.footnote);
    }
    cursor = end;
  }
  // 光标恰好在块末时仍可查询最后一个片段；屏幕点击另按标记矩形判断。
  final last = block.runs.last;
  return display == cursor && last.link != null
      ? (link: last.link!, footnote: last.footnote)
      : null;
}

/// 点按命中链接的真实文字矩形，不使用会吸附到相邻字符的光标位置。
/// 分页、双页与滚动共用；上／下标偏移与文字绘制保持一致。
({String link, bool footnote})? readerLinkAtMeasuredPoint(
  MeasuredBlock block,
  int lineIndex,
  Offset point, {
  required TextScaler scaler,
  required double width,
  double tolerance = 0,
  bool footnotesOnly = false,
}) {
  final line = block.lines[lineIndex];
  var cursor = 0;
  for (final run in block.runs) {
    final start = cursor;
    cursor += run.text.length;
    if (run.link == null || (footnotesOnly && !run.footnote)) continue;
    final from = math.max(start, line.start), to = math.min(cursor, line.end);
    if (from >= to) continue;
    final rects = run.isScript
        ? block.scriptRectsInLine(
            lineIndex,
            from,
            to,
            scaler: scaler,
            width: width,
          )
        : block.rangeRectsInLine(
            lineIndex,
            from,
            to,
            scaler: scaler,
            width: width,
            tight: true,
          );
    for (final rect in rects) {
      if (rect.inflate(tolerance).contains(point)) {
        return (link: run.link!, footnote: run.footnote);
      }
    }
  }
  return null;
}

/// 保留现有入口；默认不扩大到相邻正文或整行空白。
({String link, bool footnote})? readerLinkNearPoint(
  ChapterLayout layout,
  int pageIndex,
  Offset position, {
  double tolerance = 0,
  bool footnotesOnly = false,
}) {
  final page = layout.page(pageIndex);
  if (page == null) return null;
  for (final fragment in page.fragments) {
    if (fragment.frameOnly) continue;
    final block = fragment.block;
    var y = fragment.y + block.textTopOf(fragment.lineFrom);
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final hit = readerLinkAtMeasuredPoint(
        block,
        i,
        position - Offset(0, y),
        scaler: layout.options.textScaler,
        width: block.layoutWidth ?? layout.contentSize.width,
        tolerance: tolerance,
        footnotesOnly: footnotesOnly,
      );
      if (hit != null) return hit;
      y += block.lines[i].height;
    }
  }
  return null;
}

/// 连续滚动使用视口内各行的坐标，不把全段的原文偏移误当成本批显示偏移。
({String link, bool footnote})? readerLinkAtScrollPoint(
  ScrollSelection selection,
  Offset position, {
  bool footnotesOnly = false,
}) {
  for (final line in selection.lines) {
    final block = line.cell.measured;
    final hit = readerLinkAtMeasuredPoint(
      block,
      line.line,
      position - Offset(0, line.y),
      scaler: selection.options.textScaler,
      width: block.layoutWidth ?? selection.options.contentWidth,
      footnotesOnly: footnotesOnly,
    );
    if (hit != null) return hit;
  }
  return null;
}

/// 兼容脚注专用查询；普通链接与脚注共用精确矩形，调用者明确选择范围。
({String link, bool footnote})? footnoteAtMeasuredPoint(
  MeasuredBlock block,
  int lineIndex,
  Offset point, {
  required TextScaler scaler,
  required double width,
  double tolerance = 0,
}) => readerLinkAtMeasuredPoint(
  block,
  lineIndex,
  point,
  scaler: scaler,
  width: width,
  tolerance: tolerance,
  footnotesOnly: true,
);

({String link, bool footnote})? footnoteNearPoint(
  ChapterLayout layout,
  int pageIndex,
  Offset position, {
  double tolerance = 0,
}) => readerLinkNearPoint(
  layout,
  pageIndex,
  position,
  tolerance: tolerance,
  footnotesOnly: true,
);

({String link, bool footnote})? footnoteAtScrollPoint(
  ScrollSelection selection,
  Offset position,
) => readerLinkAtScrollPoint(selection, position, footnotesOnly: true);

/// 从原书章节 HTML 里取出锚点处的脚注文字。
///
/// 去掉返回正文的链接（`↩`、`返回` 之类）以及脚本样式；空白折叠成单个空格。
/// 找不到锚点或内容为空时返回 null。
String? footnoteTextFromHtml(
  String html,
  String fragment, {
  int maxChars = 4000,
}) => footnoteContent(html, fragment, maxChars: maxChars).text;

/// 脚注锚点的内容：[text] 是脚注文字，[backLink] 表示这个锚点其实是正文里的
/// 引用标记（从注释点回来时就会命中它），应当按普通书内跳转处理。
({String? text, bool backLink}) footnoteContent(
  String html,
  String fragment, {
  int maxChars = 4000,
}) {
  if (fragment.isEmpty) return (text: null, backLink: false);
  final document = html_parser.parse(html);
  final target = HtmlAnchorIndex(document.querySelectorAll('[id],a[name]'))
      .find(fragment);
  if (target == null) return (text: null, backLink: false);
  var element = target;
  // MOBI/KF7 经常把空锚点放在注释段前面，或放在段首编号旁边。
  // 不能把空 a 的整个 body 当注释，也不能读到下一条注释。
  if (element.text.trim().isEmpty) {
    var wrapper = element;
    while (wrapper.parent != null &&
        _noteMarkerWrappers.contains(wrapper.parent!.localName) &&
        (wrapper.parent!.text.trim().isEmpty ||
            noteMarkerKey(wrapper.parent!.text) != null)) {
      wrapper = wrapper.parent!;
    }
    final parent = wrapper.parent;
    if (wrapper.text.trim().isNotEmpty) {
      // 空锚点与同一上标编号并列时，先取得编号包装，再判断正文回链。
      element = wrapper;
    } else if (parent != null && _noteParagraphs.contains(parent.localName)) {
      final before = _textBefore(parent, wrapper);
      if (before.isNotEmpty &&
          !(onlyNoteOpeningBrackets(before) &&
              startsWithNoteMarker(parent.text))) {
        return (text: null, backLink: true);
      }
      element = parent;
    } else {
      dom.Node? next = _nextSibling(wrapper);
      while (next != null &&
          (next is dom.Text && next.text.trim().isEmpty ||
              next is dom.Element &&
                  !next.attributes.containsKey('id') &&
                  !next.attributes.containsKey('name') &&
                  (next.localName == 'br' ||
                      // KF7 常在空锚点和注释之间插入空白 p；只跨无内容的
                      // 留白，不跨另一个锚点或图片，也不跳过真实正文。
                      next.localName == 'p' &&
                          next.querySelector(
                                '[id], [name], img, svg, hr, a[href]',
                              ) ==
                              null ||
                      _noteMarkerWrappers.contains(next.localName)) &&
                  next.text.trim().isEmpty)) {
        next = _nextSibling(next);
      }
      if (next is! dom.Element ||
          !_noteParagraphs.contains(next.localName) ||
          !_startsWithNoteMarker(next)) {
        // 有效锚点也可能落在正文图片或没有编号的普通正文段前。
        // 注释回链必须能回到这些位置；不把该正文当成脚注弹出。
        return (
          text: null,
          backLink:
              next is dom.Element &&
              _noteParagraphs.contains(next.localName) &&
              (next.text.trim().isNotEmpty ||
                  next.querySelector('img,svg') != null),
        );
      }
      element = next;
    }
  }
  // 注释段开头的编号常常本身就是一个链接：
  // `<p class="fnContent"><a id="zs1" href="#zhu1">[1]</a> 脚注正文</p>`。
  // 它和正文里的引用标记长得一样，区别是它位于注释段开头、后面跟着脚注正文；
  // 这种情况要用父段落当脚注内容，不能当成“返回正文”。
  dom.Element? markerAnchor;
  final raw = element.text.trim();
  if (raw.length <= 10) {
    // 明确的footnote/endnote容器也可能使用※等非数字编号，不依赖字形猜方向。
    final marker =
        noteMarkerKey(raw) ??
        (_noteMarkerWrappers.contains(element.localName) &&
                _inSemanticNote(element)
            ? raw
            : null);
    if (marker != null) {
      // MOBI 常把锚点放在 small/span 上，外面还有 sup 等行内包装。
      // 先跨过只含同一编号的包装，才能根据真正的正文/注释段落判断方向；
      // 不能把只有编号的 sup 当成注释段，取空内容后报“没有找到”。
      while (element.parent != null) {
        final parent = element.parent!;
        if (!_noteMarkerWrappers.contains(parent.localName) ||
            (noteMarkerKey(parent.text) ?? parent.text.trim()) != marker) {
          break;
        }
        element = parent;
      }
      final parent = element.parent;
      if (parent == null) return (text: null, backLink: true);
      final before = _textBefore(parent, element);
      final hint =
          '${parent.attributes['class'] ?? ''} '
                  '${parent.attributes['id'] ?? ''}'
              .toLowerCase();
      // 标记在段首，或前面只有“注：”这类很短的前缀，才按注释内容处理；
      // 正文里句子中间的引用标记（前面已有正文）仍然按“返回正文”处理。
      final noteLike =
          before.isEmpty ||
          // 编号链接的括号可能放在链接外：[<a id="n">6</a>]注释。
          (onlyNoteOpeningBrackets(before) &&
              startsWithNoteMarker(parent.text)) ||
          (before.length <= 4 && _noteContainerHint.hasMatch(hint));
      if (!noteLike) return (text: null, backLink: true);
      markerAnchor = element;
      element = parent;
    } else if (element.localName == 'a') {
      // 正文里的引用标记很短（`[1]`、返回箭头），注释内容通常不止这几个字
      return (text: null, backLink: true);
    }
  }
  final buffer = StringBuffer();
  void walk(dom.Node node) {
    if (identical(node, markerAnchor)) return;
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    if (tag == 'script' || tag == 'style') return;
    if (tag == 'a' && _isBackLink(node)) return;
    for (final child in node.nodes) {
      walk(child);
    }
    if (_noteParagraphs.contains(tag)) buffer.write(' ');
  }

  walk(element);
  var text = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (markerAnchor != null) {
    // 编号链接已被跳过，同时去掉留在外面的空括号。
    text = text.replaceFirst(RegExp(r'^[\[（(【\s]*[\]）)】]+\s*'), '');
  }
  // 常见脚注以序号开头（“[1] ……”），气泡里不需要重复
  text = stripLeadingBracketedNoteMarker(text);
  if (text.isEmpty) return (text: null, backLink: false);
  if (text.length > maxChars) {
    text = '${text.substring(0, maxChars)}…';
  }
  return (text: text, backLink: false);
}

/// 某个节点之前的纯文字；用来判断脚注编号是不是位于注释段落开头。
String _textBefore(dom.Element parent, dom.Node child) {
  final buffer = StringBuffer();
  for (final node in parent.nodes) {
    if (identical(node, child)) break;
    buffer.write(node.text);
  }
  return buffer.toString().trim();
}

/// 注释容器常见的 class／id 关键字。只在编号前有“注：”这类短前缀时参考，
/// 不靠它单独判断，避免把正文里带 `note` 字样的普通段落误当成脚注。
final RegExp _noteContainerHint = RegExp(
  r'fn|footnote|endnote|note|annotation|comment',
  caseSensitive: false,
);

bool _inSemanticNote(dom.Element element) {
  for (dom.Element? p = element; p != null; p = p.parent) {
    final types = (p.attributes['epub:type'] ?? '').split(RegExp(r'\s+'));
    final roles = (p.attributes['role'] ?? '').split(RegExp(r'\s+'));
    if (types.any(const {'footnote', 'endnote'}.contains) ||
        roles.any(const {'doc-footnote', 'doc-endnote'}.contains)) {
      return true;
    }
  }
  return false;
}

const _noteParagraphs = {'p', 'li', 'dd', 'aside'};

dom.Node? _nextSibling(dom.Node node) {
  final siblings = node.parentNode?.nodes;
  if (siblings == null) return null;
  final index = siblings.indexOf(node) + 1;
  return index < siblings.length ? siblings[index] : null;
}

bool _startsWithNoteMarker(dom.Element element) {
  if ((element.attributes['epub:type'] ?? '').contains('footnote') ||
      (element.attributes['role'] ?? '').contains('doc-footnote')) {
    return true;
  }
  return startsWithNoteMarker(element.text);
}

const _noteMarkerWrappers = {
  'a',
  'span',
  'sup',
  'sub',
  'small',
  'b',
  'strong',
  'i',
  'em',
  'u',
  'font',
  's',
};

/// 返回正文的链接：文字是箭头／数字／“返回”之类的短标记。
bool _isBackLink(dom.Element anchor) {
  final text = anchor.text.trim();
  if (text.isEmpty) return true;
  if (noteMarkerKey(text) != null) return true;
  if (text.length <= 3 && RegExp(r'^[↩⏎↑⇧\^\d\s]+$').hasMatch(text)) {
    return true;
  }
  return const {'返回', '回', '返回正文', '查看正文'}.contains(text);
}

/// 共用书内链接处理：脚注先弹气泡，普通链接直接定位到正文或目录目标。
///
/// 成功返回 true；找不到目标章节、锚点或文字时返回 false（调用方提示）。
Future<bool> openReaderLink(
  BuildContext context, {
  required WidgetRef ref,
  required String bookId,
  required List<Chapter> chapters,
  required String link,
  required bool footnote,
  required Offset anchor,
  required ReadingTheme theme,
  bool allowBackLink = true,
}) async {
  final hash = link.lastIndexOf('#');
  final entryPath = hash < 0 ? link : link.substring(0, hash);
  final fragment = hash < 0 ? '' : link.substring(hash + 1);
  if (footnote && fragment.isEmpty) return false;
  // 本次查询期间保留原书服务；气泡关闭后再释放
  final subscription = ref.listenManual(
    originalLayoutProvider(bookId),
    (_, _) {},
  );
  try {
    final controller = await ref.read(originalLayoutProvider(bookId).future);
    final ordinal = controller.source.ordinalOfEntry(entryPath);
    if (ordinal == null || ordinal >= chapters.length) return false;
    if (!context.mounted) return true;
    if (!footnote) {
      await ref
          .read(readerSessionProvider(bookId).notifier)
          .goToChapterFromToc(
            chapters[ordinal].id,
            anchorId: fragment.isEmpty ? null : fragment,
          );
      return true;
    }
    final html = await controller.source.chapterDocument(ordinal);
    final content = html == null
        ? (text: null, backLink: false)
        : footnoteContent(html, fragment);
    if (!context.mounted) return true;
    if (content.backLink) {
      if (!allowBackLink) return false;
      // 点的是注释里的“返回正文”链接：按普通书内跳转回原位置，并保留返回原进度
      await ref
          .read(readerSessionProvider(bookId).notifier)
          .goToChapterFromToc(chapters[ordinal].id, anchorId: fragment);
      return true;
    }
    if (content.text == null) return false;
    await showFootnotePopover(
      context,
      anchor: Rect.fromCenter(center: anchor, width: 1, height: 1),
      theme: theme,
      text: content.text!,
      onJump: () {
        ref
            .read(readerSessionProvider(bookId).notifier)
            .goToChapterFromToc(chapters[ordinal].id, anchorId: fragment);
      },
    );
    return true;
  } on Object {
    return false;
  } finally {
    subscription.close();
  }
}

/// 图片脚注优先查注释；找不到文字时交回图片查看流程。
Future<bool> openReaderImageNote(
  BuildContext context, {
  required WidgetRef ref,
  required String bookId,
  required List<Chapter> chapters,
  required String? link,
  required Offset point,
  required ReadingTheme theme,
}) async {
  if (link == null) return false;
  final box = context.findRenderObject()! as RenderBox;
  return openReaderLink(
    context,
    ref: ref,
    bookId: bookId,
    chapters: chapters,
    link: link,
    footnote: true,
    anchor: box.localToGlobal(point),
    theme: theme,
    allowBackLink: false,
  );
}

/// 打开脚注气泡：正文内容是脚注文字，右下角“跳转”去原书位置。
Future<void> showFootnotePopover(
  BuildContext context, {
  required Rect anchor,
  required ReadingTheme theme,
  required String text,
  required VoidCallback onJump,
}) => showThoughtPopover(
  context,
  anchor: anchor,
  body: text,
  theme: theme,
  title: '脚注',
  actionLabel: '跳转',
  onAction: () {
    Navigator.of(context).pop();
    onJump();
  },
);
