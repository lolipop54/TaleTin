import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/services/txt_chapter_sections.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import '../../../../engine/layout/block_measurement_cache.dart';
import '../../../../engine/normalization/locator_mapper.dart';
import '../widgets/reader_performance.dart';

typedef ScrollEntry = ({
  int index,
  int section,
  int part,
  int partCount,
  bool chapterStart,
  bool chapterEnd,
  bool sectioned,
  int textOffset,
  ScrollChapter layout,
});
typedef _ScrollKey = (int, int, int);

extension on ScrollEntry {
  _ScrollKey get key => (index, section, part);
  bool before(_ScrollKey other) =>
      index < other.$1 ||
      (index == other.$1 &&
          (section < other.$2 || (section == other.$2 && part < other.$3)));
  bool get atStart => index == 0 && chapterStart;
  bool atEnd(int count) => index == count - 1 && chapterEnd;
}

/// 一次解码约八千字。滚动先排其中贴近目标的几段，滑近边界时再接着排。
class _TxtScrollSection {
  _TxtScrollSection(this.content)
    : parts = TxtChapterSections(
        content.blocks.map((block) => block.textLength),
        target: 800,
      );

  final ChapterContent content;
  final TxtChapterSections parts;

  ChapterContent contentOf(int part) => ChapterContent(
    chapterId: content.chapterId,
    blocks: content.blocks.sublist(
      parts.starts[part].paragraph,
      part + 1 < parts.starts.length
          ? parts.starts[part + 1].paragraph
          : content.blocks.length,
    ),
    stylesJson: content.stylesJson,
  );
}

/// 首次列表布局就使用目标距离，不先画零位置再在下一帧跳过去。
class _AnchorScrollController extends ScrollController {
  _AnchorScrollController() : super(keepScrollOffset: false);
  double landingOffset = 0;
  @override
  double get initialScrollOffset => landingOffset;
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _AnchorScrollPosition(
    physics: physics,
    context: context,
    initialPixels: landingOffset,
    oldPosition: oldPosition,
  );
}

class _AnchorScrollPosition extends ScrollPositionWithSingleContext {
  _AnchorScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    super.oldPosition,
  }) : super(keepScrollOffset: false);
  double pendingCorrection = 0;
  bool alignAfterLayout = false;
  double? _correctedPixels;

  @override
  bool applyViewportDimension(double viewportDimension) {
    if (pendingCorrection != 0) {
      if (alignAfterLayout) {
        _correctedPixels = pixels + pendingCorrection;
      } else {
        correctBy(pendingCorrection);
        pendingCorrection = 0;
      }
    }
    return super.applyViewportDimension(viewportDimension);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // 惯性先推进。等新列表算出尺寸和自己的位置修正之后，再用新坐标
    // 落回原句；返回 false 让视口在同一帧按修正后的距离排版。
    if (_correctedPixels case final target?) {
      _correctedPixels = null;
      pendingCorrection = 0;
      final next = target.clamp(minScrollExtent, maxScrollExtent);
      if ((next - pixels).abs() > .00001) {
        correctBy(next - pixels);
        return false;
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// 保留可见章及前后章。章节增删时补偿滚动距离，屏幕上的文字位置不变。
class ScrollWindow extends ChangeNotifier {
  ScrollWindow({
    required this.bookId,
    required this.version,
    required this.chapters,
    required this.load,
    required this.onPosition,
    this.loadTxtSections,
    this.prepareFonts,
    this.prepareResources,
    this.onError,
  });
  final String bookId;
  final int version;
  final List<Chapter> chapters;
  final Future<ChapterContent> Function(Chapter) load;
  final Future<TxtChapterSource?> Function(Chapter)? loadTxtSections;
  final PreparePublicationFonts? prepareFonts;
  final void Function(ChapterContent, Locator, int?) onPosition;
  final Future<void> Function(ScrollChapter, double, double)? prepareResources;
  final void Function(Object, StackTrace)? onError;
  final controller = _AnchorScrollController();
  final _measurements = BlockMeasurementCache();
  List<ScrollEntry> entries = [];
  Map<Key, int> _cellIndices = {};
  Key keyAt(int index) {
    final value = cellAt(index), cell = value.cell;
    return ValueKey(
      'scroll-${value.entry.index}-${cell.block.id}-${cell.offset}-${cell.from}',
    );
  }

  int? indexOfKey(Key key) => _cellIndices[key];
  void _replace(List<ScrollEntry> next) {
    entries = next;
    _cellIndices = {for (var i = 0; i < cellCount; i++) keyAt(i): i};
  }

  LayoutOptions? options;
  bool busy = false;
  bool _opening = false;
  bool _landing = false;
  _ScrollKey? _center;
  final _txtSources = <int, Future<TxtChapterSource?>>{};
  final _txtSections = <(int, int), Future<_TxtScrollSection>>{};
  bool get reachesBookEnd =>
      entries.isNotEmpty && entries.last.atEnd(chapters.length);
  bool get isReady => options != null && !_opening && !_landing;
  bool _disposed = false;
  int _request = 0;
  int? _appliedJump;
  int get cellCount => entries.fold(0, (n, e) => n + e.layout.cells.length);
  double get height => entries.fold(0, (n, e) => n + e.layout.height);

  ({ScrollEntry entry, ScrollCell cell}) cellAt(int index) {
    for (final entry in entries) {
      if (index < entry.layout.cells.length) {
        return (entry: entry, cell: entry.layout.cells[index]);
      }
      index -= entry.layout.cells.length;
    }
    throw RangeError.index(index, entries);
  }

  Future<TxtChapterSource?> _txtSource(int index) async {
    final loader = loadTxtSections;
    final chapter = chapters[index];
    if (loader == null || chapter.textLength < kLongTxtChapterLength) {
      return null;
    }
    final source = _txtSources.remove(index) ?? loader(chapter);
    _txtSources[index] = source;
    while (_txtSources.length > 4) {
      _txtSources.remove(_txtSources.keys.first);
    }
    try {
      return await source;
    } catch (_) {
      if (identical(_txtSources[index], source)) _txtSources.remove(index);
      rethrow;
    }
  }

  Future<_TxtScrollSection> _txtSection(
    int index,
    int section,
    TxtChapterSource source,
  ) async {
    final key = (index, section);
    final payload =
        _txtSections.remove(key) ??
        measureReader('simplified.scroll.load', () async {
          return _TxtScrollSection(await source.readSection(section));
        });
    _txtSections[key] = payload;
    while (_txtSections.length > 4) {
      _txtSections.remove(_txtSections.keys.first);
    }
    try {
      return await payload;
    } catch (_) {
      if (identical(_txtSections[key], payload)) _txtSections.remove(key);
      rethrow;
    }
  }

  Future<ScrollEntry> _prepare(
    _ScrollKey key,
    LayoutOptions value,
    int request,
  ) async {
    if (options?.layoutSignature == value.layoutSignature) {
      final held = entries.where((entry) => entry.key == key).firstOrNull;
      if (held != null) return held;
    }
    final (index, section, part) = key;
    final source = await _txtSource(index);
    if (_disposed || request != _request) {
      throw const ScrollPreparationCancelled();
    }
    final loaded = source == null
        ? null
        : await _txtSection(index, section, source);
    final partCount = loaded?.parts.starts.length ?? 1;
    final content =
        loaded?.contentOf(part) ??
        await measureReader<ChapterContent>(
          'simplified.scroll.load',
          () => load(chapters[index]),
        );
    final chapterStart = section == 0 && part == 0;
    final chapterEnd =
        section + 1 == (source?.starts.length ?? 1) && part + 1 == partCount;
    final prepared =
        value.settings.useBookFontsInSimplified && prepareFonts != null
        ? await prepareFonts!(bookId, content, value)
        : value;
    final layout = await measureReader(
      'simplified.scroll.layout',
      () => ScrollChapter.prepare(
        content,
        prepared,
        cancelled: () => _disposed || request != _request,
        chapterTitle: chapters[index].title,
        chapterStart: chapterStart,
        chapterEnd: chapterEnd,
        measurementCache: _measurements,
      ),
    );
    return (
      index: index,
      section: section,
      part: part,
      partCount: partCount,
      chapterStart: chapterStart,
      chapterEnd: chapterEnd,
      sectioned: source != null,
      textOffset: source == null
          ? 0
          : source.starts[section].textOffset +
                loaded!.parts.starts[part].offset,
      layout: layout,
    );
  }

  Future<ScrollEntry> _prepareNeighbor(
    ScrollEntry entry,
    LayoutOptions value,
    int request, {
    required bool forward,
  }) async {
    final index = entry.index, section = entry.section, part = entry.part;
    if (forward) {
      final next = entry.chapterEnd
          ? (index + 1, 0, 0)
          : part + 1 < entry.partCount
          ? (index, section, part + 1)
          : (index, section + 1, 0);
      return _prepare(next, value, request);
    }
    if (part > 0) return _prepare((index, section, part - 1), value, request);
    final previousIndex = entry.chapterStart ? index - 1 : index;
    final source = await _txtSource(previousIndex);
    final previousSection = entry.chapterStart
        ? (source?.starts.length ?? 1) - 1
        : section - 1;
    final previous = source == null
        ? null
        : await _txtSection(previousIndex, previousSection, source);
    return _prepare(
      (
        previousIndex,
        previousSection,
        (previous?.parts.starts.length ?? 1) - 1,
      ),
      value,
      request,
    );
  }

  Future<void> open(
    int index,
    LayoutOptions value,
    Locator? anchor, {
    int? jumpToken,
    bool animated = false,
  }) async {
    final request = ++_request;
    busy = true;
    _opening = true;
    try {
      final source = await _txtSource(index);
      if (_disposed || request != _request) return;
      final paragraph = anchor == null
          ? 0
          : TxtChapterSource.paragraphOf(anchor.blockId) ?? 0;
      final section = source?.forParagraph(paragraph) ?? 0;
      final part = source == null
          ? 0
          : (await _txtSection(
              index,
              section,
              source,
            )).parts.containingParagraph(
              paragraph - source.starts[section].paragraph,
            );
      if (_disposed || request != _request) return;
      final key = (index, section, part);
      final held = options?.layoutSignature == value.layoutSignature
          ? entries.where((e) => e.key == key).firstOrNull
          : null;
      final heldBefore = entries
          .where((e) => e.before(key))
          .fold<double>(0, (sum, e) => sum + e.layout.height);
      final heldY =
          heldBefore +
          (held == null || anchor == null ? 0 : held.layout.offsetOf(anchor));
      final covered =
          entries.isNotEmpty &&
          (entries.first.atStart || heldY >= value.contentHeight) &&
          (reachesBookEnd || height - heldY >= value.contentHeight * 2);
      if (held != null && controller.hasClients && (covered || animated)) {
        final local = anchor == null ? 0.0 : held.layout.offsetOf(anchor);
        await prepareResources?.call(held.layout, local, value.contentHeight);
        if (_disposed || request != _request) return;
        _appliedJump = jumpToken;
        if (animated) {
          // 听书复用当前列表，逐帧平移；完成前不回报中途的页首位置。
          await controller.animateTo(
            (heldBefore + local).clamp(
              controller.position.minScrollExtent,
              controller.position.maxScrollExtent,
            ),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOutCubic,
          );
          if (_disposed || request != _request) return;
          _opening = false;
          report();
          return;
        }
        _commitOffset(heldBefore + local);
        return;
      }
      final target = await _prepare(key, value, request);
      final local = anchor == null ? 0.0 : target.layout.offsetOf(anchor);
      final next = await _around(
        target,
        local,
        value,
        request,
        // 新建滚动窗口时就把锚点附近的短批次备齐，避免交接帧立即改列表起点。
        visibleOnly:
            target.layout.content.pdfPage != null ||
            target.sectioned && (controller.hasClients || paragraph == 0),
      );
      if (_disposed || request != _request) return;
      final before = next
          .where((e) => e.before(key))
          .fold<double>(0, (sum, e) => sum + e.layout.height);
      final offset = before + local;
      for (final entry in next) {
        await prepareResources?.call(
          entry.layout,
          entry.before(key)
              ? entry.layout.height - value.contentHeight
              : entry.key == key
              ? offset - before
              : 0,
          value.contentHeight,
        );
      }
      if (_disposed || request != _request) return;
      options = value;
      _center = key;
      _appliedJump = jumpToken;
      _replace(next);
      _commitOffset(offset);
    } on ScrollPreparationCancelled {
      // 换字号、跳转或退出后，旧测量不再改动当前画面。
    } finally {
      if (!_disposed && request == _request) {
        busy = false;
        _opening = false;
        if (animated) _maintainLater();
      }
    }
  }

  void _commitOffset(double offset, {bool stop = true}) {
    final request = _request;
    _landing = true;
    controller.landingOffset = offset;
    if (controller.hasClients) {
      final position = controller.position as _AnchorScrollPosition;
      if (stop) {
        position.goIdle();
        position.pendingCorrection = 0;
        position.correctBy(offset - controller.offset);
      } else {
        position.alignAfterLayout = entries.any((entry) => entry.sectioned);
        position.pendingCorrection += offset - controller.offset;
      }
    }
    notifyListeners();
    // 更新可能发生在当前帧的布局之后。等新列表真正完成布局，才能用
    // 补偿后的距离回报位置，否则会拿旧距离去读新列表，并继续向前补错段。
    _awaitOffsetLayout(request);
  }

  void _awaitOffsetLayout(int request) {
    final binding = WidgetsBinding.instance;
    binding.scheduleFrameCallback((_) {
      binding.addPostFrameCallback((_) {
        if (_disposed || request != _request || !controller.hasClients) return;
        final position = controller.position as _AnchorScrollPosition;
        if (position.pendingCorrection != 0) {
          // RenderViewport 还没收到新列表，先保留已确认的位置。
          _awaitOffsetLayout(request);
          return;
        }
        _landing = false;
        notifyListeners();
        report();
        _maintainLater();
      });
    });
  }

  ({ScrollEntry entry, double local, double before})? visible() {
    if (!controller.hasClients || entries.isEmpty) return null;
    var before = 0.0;
    final y = controller.offset;
    for (final entry in entries) {
      // 补偿做减法再加法后可能落在章界前几个小数位，不能误报为上一章。
      if (y + 0.00001 < before + entry.layout.height || entry == entries.last) {
        return (entry: entry, local: y - before, before: before);
      }
      before += entry.layout.height;
    }
    return null;
  }

  void report() {
    if (_opening || _landing) return;
    final current = visible();
    if (current == null || current.entry.layout.cells.isEmpty) return;
    final layout = current.entry.layout;
    final watch = readerPerformanceEnabled ? (Stopwatch()..start()) : null;
    final locator = layout.anchorAt(
      current.local,
      LocatorMapper(
        bookId: bookId,
        contentVersion: version,
        chapterId: chapters[current.entry.index].id,
      ),
    );
    onPosition(layout.content, locator, _appliedJump);
    if (watch != null) {
      readerPerf('simplified.scroll.report', watch.elapsedMicroseconds);
    }
  }

  Future<void> maintain() async {
    if (busy || _landing || options == null) return;
    final current = visible();
    if (current == null) return;
    final key = current.entry.key;
    final y = controller.offset, viewport = options!.contentHeight;
    // 一章可能只有封面或几十个字，必须按距离补齐，不能只看章数。
    if (_center == key &&
        (entries.first.atStart || y >= viewport) &&
        (reachesBookEnd || height - y >= viewport * 2)) {
      return;
    }
    busy = true;
    final request = _request;
    var retry = false;
    try {
      final next = await _around(
        current.entry,
        current.local,
        options!,
        request,
      );
      if (_disposed || request != _request) return;
      final visibleKey = visible()?.entry.key;
      if (visibleKey == null || !next.any((e) => e.key == visibleKey)) {
        retry = true;
        return;
      }
      _center = key;
      if (next.first.key == entries.first.key &&
          next.last.key == entries.last.key) {
        return;
      }
      // 使用完成时的距离，准备期间用户继续拖动也不会被拉回旧位置。
      var oldBefore = 0.0, newBefore = 0.0;
      for (final e in entries) {
        if (e.before(key)) oldBefore += e.layout.height;
      }
      for (final e in next) {
        if (e.before(key)) newBefore += e.layout.height;
      }
      final offset = controller.offset + newBefore - oldBefore;
      var before = 0.0;
      for (final entry in next) {
        await prepareResources?.call(
          entry.layout,
          offset - before,
          options!.contentHeight,
        );
        before += entry.layout.height;
      }
      if (_disposed || request != _request) return;
      // 图片等待期间也可能继续拖动，最后补偿必须使用此刻的位置。
      final latest = visible()?.entry.key;
      if (latest == null || !next.any((e) => e.key == latest)) {
        retry = true;
        return;
      }
      final finalOffset = controller.offset + newBefore - oldBefore;
      _replace(next);
      _commitOffset(finalOffset, stop: false);
    } on ScrollPreparationCancelled {
      // 已有更新的定位请求。
    } finally {
      if (!_disposed && request == _request) {
        busy = false;
        // 快速反向后即使停在边缘、没有新的滚动事件，也要补此刻需要的方向。
        if (retry) scheduleMicrotask(_maintainLater);
      }
    }
  }

  void _maintainLater() => unawaited(
    maintain().catchError((Object error, StackTrace stack) {
      onError?.call(error, stack);
    }),
  );

  Future<List<ScrollEntry>> _around(
    ScrollEntry target,
    double local,
    LayoutOptions value,
    int request, {
    bool visibleOnly = false,
  }) async {
    final next = <ScrollEntry>[target];
    var above = local, below = target.layout.height - local;
    // 长 TXT 和 PDF 跳转只等目标屏幕所需的内容。落地后再准备上下余量，
    // 不让前后数张扫描页的无损编码阻塞目标页显示。
    final reserve = visibleOnly ? 0.0 : value.contentHeight * 2;
    final requiredBelow = visibleOnly ? value.contentHeight : reserve * 1.5;
    // A long current chapter can already cover many screens. Prepare adjacent
    // chapters only when the same distance reserve requires them; short chapters
    // still fill two screens above and three below before the window is shown.
    while (!next.first.atStart && above < reserve) {
      final entry = await _prepareNeighbor(
        next.first,
        value,
        request,
        forward: false,
      );
      next.insert(0, entry);
      above += entry.layout.height;
    }
    while (!next.last.atEnd(chapters.length) && below < requiredBelow) {
      final entry = await _prepareNeighbor(
        next.last,
        value,
        request,
        forward: true,
      );
      next.add(entry);
      below += entry.layout.height;
    }
    while (visibleOnly &&
        !next.first.atStart &&
        above + below < value.contentHeight) {
      final entry = await _prepareNeighbor(
        next.first,
        value,
        request,
        forward: false,
      );
      next.insert(0, entry);
      above += entry.layout.height;
    }
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _measurements.clear();
    controller.dispose();
    super.dispose();
  }
}
