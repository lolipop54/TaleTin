import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import '../../../../engine/layout/block_measurement_cache.dart';
import '../../../../engine/normalization/locator_mapper.dart';
import '../widgets/reader_performance.dart';

typedef ScrollEntry = ({int index, ScrollChapter layout});

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

  @override
  bool applyViewportDimension(double viewportDimension) {
    // 动画先推进，布局再补偿；若在异步加载完成时直接改 pixels，下一次
    // 惯性 tick 会用旧坐标覆盖它。内容尺寸提交后 Flutter 自动续接当前速度。
    if (pendingCorrection != 0) {
      correctBy(pendingCorrection);
      pendingCorrection = 0;
    }
    return super.applyViewportDimension(viewportDimension);
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
    this.prepareResources,
    this.onError,
  });
  final String bookId;
  final int version;
  final List<Chapter> chapters;
  final Future<ChapterContent> Function(Chapter) load;
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
  int? _center;
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

  Future<ScrollEntry> _prepare(
    int index,
    LayoutOptions value,
    int request,
  ) async {
    if (options?.layoutSignature == value.layoutSignature) {
      final held = entries.where((entry) => entry.index == index).firstOrNull;
      if (held != null) return held;
    }
    final content = await measureReader(
      'simplified.scroll.load',
      () => load(chapters[index]),
    );
    final layout = await measureReader(
      'simplified.scroll.layout',
      () => ScrollChapter.prepare(
        content,
        value,
        cancelled: () => _disposed || request != _request,
        chapterTitle: chapters[index].title,
        measurementCache: _measurements,
      ),
    );
    return (index: index, layout: layout);
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
      final held = options?.layoutSignature == value.layoutSignature
          ? entries.where((e) => e.index == index).firstOrNull
          : null;
      final heldBefore = entries
          .where((e) => e.index < index)
          .fold<double>(0, (sum, e) => sum + e.layout.height);
      final heldY =
          heldBefore +
          (held == null || anchor == null ? 0 : held.layout.offsetOf(anchor));
      final covered =
          entries.isNotEmpty &&
          (entries.first.index == 0 || heldY >= value.contentHeight) &&
          (entries.last.index == chapters.length - 1 ||
              height - heldY >= value.contentHeight * 2);
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
      final target = await _prepare(index, value, request);
      final local = anchor == null ? 0.0 : target.layout.offsetOf(anchor);
      final next = await _around(target, local, value, request);
      if (_disposed || request != _request) return;
      final before = next
          .where((e) => e.index < index)
          .fold<double>(0, (sum, e) => sum + e.layout.height);
      final offset = before + local;
      for (final entry in next) {
        await prepareResources?.call(
          entry.layout,
          entry.index < index
              ? entry.layout.height - value.contentHeight
              : entry.index == index
              ? offset - before
              : 0,
          value.contentHeight,
        );
      }
      if (_disposed || request != _request) return;
      options = value;
      _center = index;
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
        position.pendingCorrection += offset - controller.offset;
      }
    }
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || request != _request || !controller.hasClients) return;
      // 新列表和新距离同帧生效。这里不再次 jumpTo，避免迟到落位打断新拖动。
      _landing = false;
      notifyListeners();
      report();
      _maintainLater();
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
    final index = current.entry.index;
    final y = controller.offset, viewport = options!.contentHeight;
    // 一章可能只有封面或几十个字，必须按距离补齐，不能只看章数。
    if (_center == index &&
        (entries.first.index == 0 || y >= viewport) &&
        (entries.last.index == chapters.length - 1 ||
            height - y >= viewport * 2)) {
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
      final visibleIndex = visible()?.entry.index;
      if (visibleIndex == null || !next.any((e) => e.index == visibleIndex)) {
        retry = true;
        return;
      }
      _center = index;
      if (next.first.index == entries.first.index &&
          next.last.index == entries.last.index) {
        return;
      }
      // 使用完成时的距离，准备期间用户继续拖动也不会被拉回旧位置。
      var oldBefore = 0.0, newBefore = 0.0;
      for (final e in entries) {
        if (e.index < index) oldBefore += e.layout.height;
      }
      for (final e in next) {
        if (e.index < index) newBefore += e.layout.height;
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
      final latest = visible()?.entry.index;
      if (latest == null || !next.any((e) => e.index == latest)) {
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
    int request,
  ) async {
    final next = <ScrollEntry>[target];
    var above = local, below = target.layout.height - local;
    final reserve = value.contentHeight * 2;
    while (next.first.index > 0 &&
        (next.first.index == target.index || above < reserve)) {
      final entry = await _prepare(next.first.index - 1, value, request);
      next.insert(0, entry);
      above += entry.layout.height;
    }
    while (next.last.index + 1 < chapters.length &&
        (next.last.index == target.index || below < reserve * 1.5)) {
      final entry = await _prepare(next.last.index + 1, value, request);
      next.add(entry);
      below += entry.layout.height;
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
