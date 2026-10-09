/// 单章排版结果：整章测量 + 分页，并负责「位置 ↔ 页」的换算。
///
/// 产出方式（实现计划第 7 节）：默认整章排完，这样章末翻页与页数都是准的；
/// 测量按小批次让出事件循环，避免长章节一次性占满 UI isolate。以后实测发现
/// 单章测量超过阈值，只需要把这里换成「排到需要处 + 后台补排」，
/// 上层接口（[pages]、[locatorOf]、[pageIndexOf]）不用动。
library;

import 'dart:ui' show Size;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../normalization/locator_mapper.dart';
import 'block_measure.dart';
import 'chapter_paginator.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'english_hyphenation.dart';
import 'table_layout.dart';

/// 排版任务令牌：参数变化或切章后旧任务作废，结果不再上屏
/// （设计文档 4.1 第 6 条：丢弃过期排版结果）。
class LayoutToken {
  LayoutToken(this.version);

  final int version;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 排版被取消（参数已变或已切章），调用方直接丢弃即可。
class LayoutCancelled implements Exception {
  const LayoutCancelled();

  @override
  String toString() => 'LayoutCancelled';
}

/// 每批测量的块数：一次让出事件循环，兼顾首屏速度与界面不卡顿
const int kMeasureBatchSize = 6;

class ChapterLayout {
  ChapterLayout._({
    required this.bookId,
    required this.contentVersion,
    required this.chapterId,
    required this.chapterTitle,
    required this.blocks,
    required this.pages,
    required this.mapper,
    required this.totalLength,
    required this.content,
    required this.options,
  });

  final String bookId;
  final int contentVersion;
  final String chapterId;
  final String chapterTitle;

  /// 与 [ChapterContent.blocks] 一一对应的测量结果（含章题装饰块）
  final List<MeasuredBlock> blocks;
  final List<PageSlice> pages;

  /// 章节内位置换算（摘录、前后文都在这一层补齐）
  final LocatorMapper mapper;

  /// 章内文本总长度，口径与 `ChapterContent.textLength` 一致
  final int totalLength;

  /// 原始正文：摘录、前后文与重定位都要回到内容块本身
  final ChapterContent content;

  /// 本次排版使用的全部参数（设置、内容区尺寸、TextScaler）。
  ///
  /// 绘制必须用它：尺寸用 [LayoutOptions.contentWidthFor]，缩放用
  /// [LayoutOptions.textScaler]，这样画出来的行与排版算出的行必然一致。
  /// 界面按 [contentSize] 绘制每一页：改字号或换窗口尺寸时，新排版算完之前继续
  /// 按旧尺寸显示，不会出现半页文字按新宽度重排的中间态（设计文档 9.7）。
  final LayoutOptions options;

  /// 本次排版使用的内容区尺寸
  Size get contentSize => options.contentSize;

  /// 块 ID → 内容块，按需构建（摘录只在生成 Locator 时用到）
  late final Map<String, ContentBlock> _contentBlocks = {
    for (final block in content.blocks) block.id: block,
  };

  int get pageCount => pages.length;

  bool get isEmpty => pages.isEmpty;

  PageSlice? page(int index) =>
      index >= 0 && index < pages.length ? pages[index] : null;

  /// 章首锚点：第一页的第一行
  Locator get startLocator =>
      beginLocatorOf(pages.isEmpty ? null : pages.first);

  Locator beginLocatorOf(PageSlice? slice) {
    if (slice == null || slice.fragments.isEmpty) {
      return _locatorFor(PageAnchor(blockId: '', utf16Offset: 0));
    }
    // 章题仅用于显示；图片也是有效正文位置，听书会从它向后寻找文字。
    if (slice.start.blockId == BlockMeasurer.titleBlockId) {
      for (final fragment in slice.fragments) {
        if (fragment.block.isDecoration) {
          continue;
        }
        return _locatorFor(PageAnchor(
          blockId: fragment.block.blockId,
          utf16Offset: fragment.block.lines.isEmpty
              ? 0
              : fragment.block.lines[fragment.lineFrom].start,
        ));
      }
      // 标题独占一页时也不能把装饰块 ID 保存为阅读位置。
      return mapper.chapterStart(content.blocks);
    }
    return _locatorFor(slice.start);
  }

  Locator endLocatorOf(PageSlice? slice) {
    if (slice == null || slice.fragments.isEmpty) {
      return _locatorFor(PageAnchor(blockId: '', utf16Offset: 0));
    }
    return _locatorFor(slice.end);
  }

  /// 页内进度 0–1：按该页首字符在章内文本流中的位置估算。
  ///
  /// 只用内容位置算，与排版无关——所以改字号、换主题都不会让进度跳变
  /// （设计文档 6.3）。
  double progressOfPage(int pageIndex) {
    final slice = page(pageIndex);
    if (slice == null || totalLength <= 0) return 0;
    final order = _orderOf(slice.start.blockId);
    if (order < 0) return 0;
    // 分母用标准化正文长度（与全书百分比同口径），分子也换算到同一坐标系
    var consumed = 0;
    for (var i = 0; i < order && i < blocks.length; i++) {
      final block = blocks[i];
      if (block.isDecoration) continue;
      consumed += block.text.length - block.displayPrefixLength + 1;
    }
    final position = consumed + _blockOffsetOf(slice.start);
    return (position / totalLength).clamp(0.0, 1.0);
  }

  /// 页锚点的偏移（测量文本坐标系）→ 标准化正文坐标系。
  ///
  /// 首行缩进是两个画出来的全角空格，会进入测量文本；Locator 的偏移不含它。
  int _blockOffsetOf(PageAnchor anchor) {
    final position = _positionOfBlock(anchor.blockId);
    if (position == null) return anchor.utf16Offset;
    final offset = anchor.utf16Offset - position.displayPrefixLength;
    return offset < 0 ? 0 : offset;
  }

  MeasuredBlock? _positionOfBlock(String blockId) {
    for (final block in blocks) {
      if (block.blockId == blockId) return block;
    }
    return null;
  }

  /// 页首锚点 → 完整 Locator（补齐摘录、前后文）
  Locator _locatorFor(PageAnchor anchor) {
    final block = _contentBlockOf(anchor.blockId);
    if (block == null) {
      return Locator(
        bookId: bookId,
        contentVersion: contentVersion,
        chapterId: chapterId,
        blockId: anchor.blockId,
        utf16Offset: anchor.utf16Offset,
        affinity: anchor.affinity,
      );
    }
    return mapper.at(block, _blockOffsetOf(anchor), affinity: anchor.affinity);
  }

  ContentBlock? _contentBlockOf(String blockId) => _contentBlocks[blockId];

  /// 块在 [blocks] 中的下标；不在本章时返回 -1。
  /// 章题装饰块是 0，因此正文块的顺序天然排在它后面。
  int _orderOf(String blockId) {
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].blockId == blockId) return i;
    }
    return -1;
  }

  /// 位置 → 章内页序：从章首重放比较锚点，不做第二套回填算法
  /// （实现计划 5.4）。位置不在本章时返回 null。
  int? pageIndexOf(Locator locator) {
    if (locator.chapterId != chapterId) return null;
    if (_orderOf(locator.blockId) < 0) return null;
    // 表格跨页时同一行的各列同时续排，不能用首尾块号推断整页范围。
    if (_positionOfBlock(locator.blockId)?.tableId != null) {
      for (final slice in pages) {
        for (final fragment in slice.fragments) {
          if (fragment.frameOnly || fragment.block.blockId != locator.blockId) continue;
          final lines = fragment.block.lines;
          if (lines.isEmpty || (locator.utf16Offset >= lines[fragment.lineFrom].start &&
              (locator.utf16Offset < lines[fragment.lineTo - 1].end ||
                fragment.lineTo == lines.length))) { return slice.index; }
        }
      }
    }
    for (final slice in pages) {
      // 半开区间 [start, end)：页首锚点属于本页，页尾锚点属于下一页
      if (_compare(locator, slice.start) >= 0 &&
          _compare(locator, slice.end) < 0) {
        return slice.index;
      }
    }
    // 落在全书该章最后位置之后（例如章尾空块）：归到最后一页
    return pages.isEmpty ? null : pages.length - 1;
  }

  /// 内容顺序比较：先比块序，再比块内偏移，最后比定位倾向。
  ///
  /// 倾向参与比较是为了让图片块有个稳定的上下沿：页尾锚点带 after、
  /// 页首锚点带 before，指向图片本身的位置就能稳定落在图片所在页。
  int _compare(Locator locator, PageAnchor anchor) {
    final order = _orderOf(locator.blockId);
    final anchorOrder = _orderOf(anchor.blockId);
    if (order != anchorOrder) return order.compareTo(anchorOrder);
    // 锚点在测量坐标系，先换算回标准化正文坐标系再比
    final byOffset = locator.utf16Offset.compareTo(_blockOffsetOf(anchor));
    if (byOffset != 0) return byOffset;
    return locator.affinity.value.compareTo(anchor.affinity.value);
  }

  /// 拼接页内正文文本（不含装饰块），供「不漏字、不重复」自检与测试使用。
  String textOfPage(int pageIndex) {
    final slice = page(pageIndex);
    if (slice == null) return '';
    final buffer = StringBuffer();
    for (final fragment in slice.fragments) {
      final block = fragment.block;
      if (fragment.frameOnly || block.isDecoration || block.lines.isEmpty) continue;
      buffer.write(block.text.substring(
        block.lines[fragment.lineFrom].start,
        block.lines[fragment.lineTo - 1].end,
      ));
    }
    return buffer.toString();
  }

  /// 整章正文按顺序拼接（自检用）
  String joinedPageText() {
    final buffer = StringBuffer();
    // 表格各列跨页同时续排；自检按原文块顺序收集实际页片段。
    for (final block in blocks.where((b) => !b.isDecoration && b.lines.isNotEmpty)) {
      for (final page in pages) {
        for (final fragment in page.fragments) {
          if (fragment.frameOnly || fragment.block != block) continue;
          buffer.write(block.text.substring(block.lines[fragment.lineFrom].start,
            block.lines[fragment.lineTo - 1].end));
        }
      }
    }
    return buffer.toString();
  }

  /// 按参数与正文构造一章的排版（异步、分批测量、可取消）。
  static Future<ChapterLayout> produce({
    required String bookId,
    required int contentVersion,
    required Chapter chapter,
    required ChapterContent content,
    required LayoutOptions options,
    LayoutToken? token,
  }) async {
    await EnglishHyphenation.prepare();
    final measurer = BlockMeasurer(options);
    final mapper = LocatorMapper(
      bookId: bookId,
      contentVersion: contentVersion,
      chapterId: chapter.id,
    );
    // 章首标题：正文里本来就有同名标题时直接把它当章题画，
    // 否则补一个装饰块，避免同一句话出现两遍
    final useContentHeading = firstBlockIsChapterTitle(content, chapter.title);
    final measured = <MeasuredBlock>[
      if (!useContentHeading && chapter.title.trim().isNotEmpty)
        measurer.measureChapterTitle(chapter.title),
    ];
    var batch = 0;
    final byId = {for (final block in content.blocks) block.id: block};
    final tables = {for (final table in content.tables) table.blockIds.first: table};
    final tableIds = content.tables.expand((t) => t.blockIds).toSet();
    for (var i = 0; i < content.blocks.length; i++) {
      final block = content.blocks[i];
      if (token?.isCancelled ?? false) throw const LayoutCancelled();
      final table = tables[block.id];
      if (table != null) {
        measured.addAll(measureTable(table, byId, options));
        await Future<void>.delayed(Duration.zero);
      }
      if (tableIds.contains(block.id)) continue;
      // 首行缩进只给普通正文段落，且只在段首那一片
      final withIndent = options.settings.indent &&
          block.kind == BlockKind.paragraph;
      measured.add(measurer.measure(
        block,
        withIndent: withIndent,
        asChapterTitle: useContentHeading && i == 0,
      ));
      if (++batch >= kMeasureBatchSize) {
        batch = 0;
        // 让出事件循环：测量是 CPU 活，不阻塞手势与动画
        await Future<void>.delayed(Duration.zero);
      }
    }

    final paginator = ChapterPaginator(
      pageHeight: options.contentHeight,
      gapBefore: measurer.gapBefore,
    );
    final pages = paginator.paginate(measured);
    if (token?.isCancelled ?? false) throw const LayoutCancelled();

    return ChapterLayout._(
      bookId: bookId,
      contentVersion: contentVersion,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      blocks: measured,
      pages: pages,
      mapper: mapper,
      totalLength: mapper.totalLength(content.blocks),
      content: content,
      options: options,
    );
  }

  /// 章节的第一个块是不是「和章名一样的标题」。
  ///
  /// 大多数可重排 EPUB 的第一块就是章名（`<h1>第一章</h1>`），而阅读页顶部已经
  /// 显示章题，两边都画就会出现同一句话连排两遍。比较时忽略空白与大小写。
  ///
  /// 标题不一定写成 `<h1>`：也有书把章名写成普通段落（`<p class="title">`），
  /// 这时同样按章题绘制，否则章名会连着出现两次。判定用的是文字相等，
  /// 所以不会把正文段落误认成标题。
  static bool firstBlockIsChapterTitle(
    ChapterContent content,
    String chapterTitle,
  ) {
    if (content.blocks.isEmpty) return false;
    final first = content.blocks.first;
    if (first.kind != BlockKind.heading && first.kind != BlockKind.paragraph) {
      return false;
    }
    return _normalizeTitle(blockTextOf(first)) ==
        _normalizeTitle(chapterTitle);
  }

  static String _normalizeTitle(String text) =>
      text.replaceAll(RegExp(r'\s+'), '').toLowerCase();
}
