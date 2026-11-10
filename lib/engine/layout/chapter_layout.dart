/// 单章排版结果：整章测量 + 分页，并负责「位置 ↔ 页」的换算。
///
/// 产出方式（实现计划第 7 节）：默认整章排完，这样章末翻页与页数都是准的；
/// 测量按小批次让出事件循环，避免长章节一次性占满 UI isolate。以后实测发现
/// 单章测量超过阈值，只需要把这里换成「排到需要处 + 后台补排」，
/// 上层接口（[pages]、[locatorOf]、[pageIndexOf]）不用动。
library;

import 'dart:async';
import 'dart:ui' show Size;

import '../../core/diagnostics/reader_work_trace.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/content_table.dart';
import '../../domain/models/locator.dart';
import '../../domain/services/layout_checkpoint_store.dart';
import '../normalization/locator_mapper.dart';
import '../styles/chapter_styler.dart';
import '../styles/css_layout_styles.dart';
import 'block_measure.dart';
import 'block_measurement_cache.dart';
import 'chapter_paginator.dart';
import 'display_tree.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'english_hyphenation.dart';
import 'table_layout.dart';
import 'parallel_flow_layout.dart';
import 'layout_work_gate.dart';
import 'measured_block_codec.dart';

part 'chapter_layout_task.dart';
part 'lazy_measured_blocks.dart';

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
    this.task,
    this.isComplete = true,
    this.firstPage = 0,
    this.consumedBeforeWindow = 0,
    Map<String, MeasuredBlock>? measuredById,
    Map<String, int>? blockOrders,
    this._consumedBefore,
  }) : _measuredLookup = measuredById,
       _orders = blockOrders;

  final String bookId;
  final int contentVersion;
  final String chapterId;
  final String chapterTitle;
  final ChapterLayoutTask? task;
  final bool isComplete;

  /// 可用窗口的首个绝对页序。磁盘恢复的旧页不会以空白占位。
  final int firstPage;
  final int consumedBeforeWindow;
  final List<int>? _consumedBefore;
  Object get identity => task ?? this;

  /// 同一封口页在补排通知后保持身份，图像与手势不随容器替换失效。
  bool samePageAs(ChapterLayout? other, int pageIndex, [int? otherIndex]) =>
      other != null &&
      page(pageIndex) != null &&
      identical(page(pageIndex), other.page(otherIndex ?? pageIndex));

  Future<ChapterLayout> ensurePage(int index) async =>
      task == null ? this : task!.ensure(page: index);
  Future<ChapterLayout> ensureTarget(Locator target) async =>
      task == null ? this : task!.ensure(target: target);
  Stream<ChapterLayout> get updates => task?.updates ?? const Stream.empty();
  void resumeBackground() => task?.resumeBackground();

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

  int get pageCount => firstPage + pages.length;

  bool get isEmpty => pages.isEmpty;

  PageSlice? page(int index) =>
      index >= firstPage && index < pageCount ? pages[index - firstPage] : null;

  /// 章首锚点：第一页的第一行
  Locator get startLocator => firstPage == 0
      ? beginLocatorOf(pages.isEmpty ? null : pages.first)
      : mapper.chapterStart(content.blocks);

  /// 高亮可能从缓存窗口之前开始。它仍覆盖当前窗口里相交的文本。
  bool precedesWindow(Locator locator) {
    if (firstPage == 0 || pages.isEmpty || locator.chapterId != chapterId) {
      return false;
    }
    for (final block in content.blocks) {
      if (block.id == pages.first.start.blockId) return false;
      if (block.id == locator.blockId) return true;
    }
    return false;
  }

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
        return _locatorFor(
          PageAnchor(
            blockId: fragment.block.blockId,
            utf16Offset: fragment.block.lines.isEmpty
                ? 0
                : fragment.block.lines[fragment.lineFrom].start,
          ),
        );
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
    var consumed = consumedBeforeWindow;
    final prefix = _consumedBefore;
    if (prefix != null) {
      consumed += prefix[order.clamp(0, blocks.length)];
    } else {
      for (var i = 0; i < order && i < blocks.length; i++) {
        final block = blocks[i];
        if (block.isDecoration && !block.isTitleDecoration) continue;
        consumed += block.text.length - block.displayPrefixLength + 1;
      }
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

  Map<String, MeasuredBlock>? _measuredLookup;
  Map<String, MeasuredBlock> get _measuredById => _measuredLookup ??= () {
    final result = <String, MeasuredBlock>{};
    for (final block in blocks) {
      if (block.isDecoration && !block.isTitleDecoration) continue;
      result.putIfAbsent(block.blockId, () => block);
    }
    return result;
  }();
  MeasuredBlock? _positionOfBlock(String blockId) => _measuredById[blockId];

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
  Map<String, int>? _orders;
  Map<String, int> get _blockOrders => _orders ??= () {
    final result = <String, int>{};
    for (var i = 0; i < blocks.length; i++) {
      result.putIfAbsent(blocks[i].blockId, () => i);
    }
    return result;
  }();
  int _orderOf(String blockId) => _blockOrders[blockId] ?? -1;

  /// 位置 → 章内页序：从章首重放比较锚点，不做第二套回填算法
  /// （实现计划 5.4）。位置不在本章时返回 null。
  int? pageIndexOf(Locator locator) => _pageIndexOf(locator);

  // 增量排版只检查本轮新增的封口页；公开查询仍从第一页开始。
  // 表格各列同时续排，继续逐片段核对，不能按首尾块号二分查找。
  int? _pageIndexOf(Locator locator, {int fromPage = 0}) {
    if (locator.chapterId != chapterId) return null;
    if (_orderOf(locator.blockId) < 0) return null;
    if (firstPage != 0 &&
        pages.isNotEmpty &&
        _compare(locator, pages.first.start) < 0) {
      return null;
    }
    // 表格跨页时同一行的各列同时续排，不能用首尾块号推断整页范围。
    if (_positionOfBlock(locator.blockId)?.tableId != null) {
      for (var i = fromPage; i < pages.length; i++) {
        final slice = pages[i];
        for (final fragment in slice.fragments) {
          if (fragment.frameOnly || fragment.block.blockId != locator.blockId) {
            continue;
          }
          final lines = fragment.block.lines;
          if (lines.isEmpty ||
              (locator.utf16Offset >= lines[fragment.lineFrom].start &&
                  (locator.utf16Offset < lines[fragment.lineTo - 1].end ||
                      fragment.lineTo == lines.length))) {
            return slice.index;
          }
        }
      }
    } else {
      // 表格目标尚未出现时继续排，不能再套普通段落的页首尾范围：
      // 同页左右列的块序可能把后续左列文字也夹在这个范围内。
      for (var i = fromPage; i < pages.length; i++) {
        final slice = pages[i];
        // 半开区间 [start, end)：页首锚点属于本页，页尾锚点属于下一页
        if (_compare(locator, slice.start) >= 0 &&
            _compare(locator, slice.end) < 0) {
          return slice.index;
        }
      }
    }
    // 落在全书该章最后位置之后（例如章尾空块）：归到最后一页
    return pages.isEmpty || !isComplete ? null : pageCount - 1;
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
      if (fragment.frameOnly || block.isDecoration || block.lines.isEmpty) {
        continue;
      }
      buffer.write(
        block.text.substring(
          block.lines[fragment.lineFrom].start,
          block.lines[fragment.lineTo - 1].end,
        ),
      );
    }
    return buffer.toString();
  }

  /// 整章正文按顺序拼接（自检用）。
  ///
  /// 硬换行只在显示层把原来的空格换成换行符（1:1 替换）；这里换回空格，
  /// 才能与标准化正文逐字比较，验证「不漏字、不重复」。
  String joinedPageText() {
    final buffer = StringBuffer();
    // 表格各列跨页同时续排；自检按原文块顺序收集实际页片段。
    for (final block in blocks.where(
      (b) => !b.isDecoration && b.lines.isNotEmpty,
    )) {
      for (final page in pages) {
        for (final fragment in page.fragments) {
          if (fragment.frameOnly || fragment.block != block) continue;
          buffer.write(
            block.text.substring(
              block.lines[fragment.lineFrom].start,
              block.lines[fragment.lineTo - 1].end,
            ),
          );
        }
      }
    }
    return buffer.toString().replaceAll('\n', ' ');
  }

  /// 按参数与正文构造一章的排版（异步、分批测量、可取消）。
  static Future<ChapterLayout> produce({
    required String bookId,
    required int contentVersion,
    required Chapter chapter,
    required ChapterContent content,
    required LayoutOptions options,
    LayoutToken? token,
    BlockMeasurementCache? measurementCache,
  }) async {
    final trace = ReaderWorkTrace.start('layout.produce', {
      'chapter': chapter.ordinal,
      'blocks': content.blocks.length,
    });
    final batchClock = readerWorkTraceEnabled ? (Stopwatch()..start()) : null;
    var maxBatchUs = 0;
    void sampleBatch() {
      if (batchClock == null) return;
      final us = batchClock.elapsedMicroseconds;
      if (us > maxBatchUs) maxBatchUs = us;
    }

    try {
      content = CssLayoutStyles.resolve(content, options);
      await EnglishHyphenation.prepare();
      trace?.mark('dictionary');
      batchClock?.reset();
      final measurer = BlockMeasurer(
        options,
        styleTable: ChapterStyler.layoutTableOf(content),
        displayTree: DisplayTree.build(content),
        cache: measurementCache,
      );
      final work = Stopwatch()..start();
      await measurer.prepareMath(content);
      final mapper = LocatorMapper(
        bookId: bookId,
        contentVersion: contentVersion,
        chapterId: chapter.id,
      );
      // 章首标题：只有 TXT 需要补。TXT 的章名被切去当目录，正文里没有标题；
      // EPUB／MOBI／AZW3／PDF 电子书尊重原书，不加标题，也不在书自己的标题下加横线。
      // TXT 正文偶尔自带同名标题时仍按章题画，避免同一句话出现两遍。
      final titleIndex = options.insertChapterTitle
          ? chapterTitleBlockIndex(content, chapter.title)
          : null;
      final useContentHeading = titleIndex != null;
      final measured = <MeasuredBlock>[
        if (options.insertChapterTitle &&
            content.pdfPage == null &&
            !useContentHeading &&
            chapter.title.trim().isNotEmpty)
          measurer.measureChapterTitle(chapter.title),
      ];
      var batch = 0;
      final byId = {for (final block in content.blocks) block.id: block};
      final tables = {
        for (final table in content.tables) table.blockIds.first: table,
      };
      final tableIds = content.tables.expand((t) => t.blockIds).toSet();
      final parallel = ParallelFlowLayout(
        content,
        measurer.displayTree!,
        ChapterStyler.layoutTableOf(content),
        options,
      );
      for (var i = 0; i < content.blocks.length; i++) {
        final block = content.blocks[i];
        measured.addAll(measurer.measureBefore(i));
        if (token?.isCancelled ?? false) throw const LayoutCancelled();
        if (parallel.groups.containsKey(i)) {
          measured.addAll(parallel.measure(i, measurer));
          i = parallel.groups[i]!.last.lastBlock!;
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        final table = tables[block.id];
        if (table != null) {
          measured.addAll(
            measureTable(
              table,
              byId,
              options,
              cache: measurementCache,
              styleTable: ChapterStyler.layoutTableOf(content),
              displayTree: measurer.displayTree,
              order: content.blocks,
            ),
          );
          sampleBatch();
          await Future<void>.delayed(Duration.zero);
          batchClock?.reset();
          work.reset();
        }
        if (tableIds.contains(block.id)) continue;
        // 首行缩进只给普通正文段落和引用块，且只在段首那一片
        final withIndent =
            options.settings.indent &&
            (block.kind == BlockKind.paragraph ||
                block.kind == BlockKind.quote);
        measured.add(
          measurer.measure(
            block,
            withIndent: withIndent,
            asChapterTitle: useContentHeading && i == 0,
          ),
        );
        if (++batch >= kMeasureBatchSize || work.elapsedMicroseconds >= 4000) {
          batch = 0;
          // 让出事件循环：测量是 CPU 活，不阻塞手势与动画
          sampleBatch();
          await Future<void>.delayed(Duration.zero);
          batchClock?.reset();
          work.reset();
        }
      }

      // 同一个盒子容器里的连续块：只有第一块画上边框／上内边距，
      // 最后一块画下边框／下内边距，中间的块与上下块连成一个盒子。
      // 这段规则在增量排版（ChapterLayoutTask）里也要执行，所以抽到 MeasuredBlock 上。
      measured.addAll(measurer.measureBefore(content.blocks.length));
      for (var i = 0; i < measured.length; i++) {
        measured[i] = measured[i].fitBoxPart(
          i == 0 ? null : measured[i - 1],
          i + 1 >= measured.length ? null : measured[i + 1],
        );
      }
      sampleBatch();
      trace?.mark('measure_with_yields');
      trace?.details['maxSynchronousBatchUs'] = maxBatchUs;
      trace?.details['reusedBlocks'] = measurer.cacheHits;
      trace?.details['measuredBlocks'] = measurer.measuredBlocks;

      final paginator = ChapterPaginator(
        pageHeight: options.contentHeight,
        gapBefore: measurer.gapBefore,
      );
      final pages = paginator.paginate(measured);
      trace?.mark('paginate');
      trace?.details['pages'] = pages.length;
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
    } catch (error) {
      trace?.finish(status: error.runtimeType.toString());
      rethrow;
    } finally {
      trace?.finish();
    }
  }

  /// 章首前几块里有没有「和章名一样的标题」。
  ///
  /// 现在只给 TXT 用：TXT 的章名被切去当目录，正文一般没有标题，所以要补一条章题；
  /// 万一正文里又自带同名标题，就按它画，避免同一句话连排两遍。判定用的是文字
  /// 相等（忽略空白与大小写），只看标题／段落，所以不会把正文误认成标题。
  /// EPUB／MOBI／AZW3 不再补章题，也不会走到这里。
  ///
  /// 不能只看第一块：章首可能是封面图或装饰图，书自己的标题在后面。
  static int? chapterTitleBlockIndex(
    ChapterContent content,
    String chapterTitle,
  ) {
    final target = _normalizeTitle(chapterTitle);
    if (target.isEmpty) return null;
    final limit = content.blocks.length < 6 ? content.blocks.length : 6;
    for (var i = 0; i < limit; i++) {
      final block = content.blocks[i];
      if (block.kind != BlockKind.heading &&
          block.kind != BlockKind.paragraph) {
        continue;
      }
      if (_normalizeTitle(blockTextOf(block)) == target) return i;
    }
    return null;
  }

  static bool firstBlockIsChapterTitle(
    ChapterContent content,
    String chapterTitle,
  ) => chapterTitleBlockIndex(content, chapterTitle) == 0;

  static String _normalizeTitle(String text) =>
      text.replaceAll(RegExp(r'\s+'), '').toLowerCase();
}
