/// [ReaderEngine] 的 Flutter 实现：把测量、分页、缓存装配起来。
///
/// 它只负责「同一份参数进来，同一份排版出去」，并做两件事：
/// 1. 命中缓存直接返回，不重复测量；
/// 2. 每次排版发一个令牌，参数变化或切章后旧令牌作废，过期结果不上屏。
library;

import 'dart:ui' show Offset, Rect;

import '../../core/diagnostics/reader_work_trace.dart';

import '../../domain/models/locator.dart';
import '../../domain/services/reader_engine.dart';
import '../selection/selection_rects.dart';
import 'chapter_layout.dart';
import 'layout_cache.dart';
import 'block_measurement_cache.dart';

class FlutterReaderEngine implements ReaderEngine {
  FlutterReaderEngine({LayoutCache? cache}) : _cache = cache ?? LayoutCache();

  final LayoutCache _cache;
  final _measurements = BlockMeasurementCache();
  int _version = 0;
  LayoutToken? _current;

  /// 当前生效的排版令牌（参数变化时作废上一个）
  LayoutToken get currentToken => _current ??= LayoutToken(++_version);

  @override
  Future<ChapterLayout> layoutChapter(
    LayoutRequest request, {
    LayoutToken? token,
  }) async {
    final trace = ReaderWorkTrace.start('layout.request', {
      'chapter': request.chapter.ordinal,
      'cancellable': token != null,
    });
    try {
      final options = request.options;
      final key = LayoutCache.keyFor(
        bookId: request.bookId,
        contentVersion: request.contentVersion,
        chapterId: request.chapter.id,
        layoutSignature: options.layoutSignature,
      );
      final cached = _cache.get(key);
      trace?.details['hit'] = cached != null;
      if (cached != null) return cached;

      final layout = await ChapterLayout.produce(
        bookId: request.bookId,
        contentVersion: request.contentVersion,
        chapter: request.chapter,
        content: request.content,
        options: options,
        token: token,
        measurementCache: _measurements,
      );
      // 结果产出后才入缓存：取消的排版不会污染后续请求
      _cache.put(key, layout);
      return layout;
    } catch (error) {
      trace?.finish(status: error.runtimeType.toString());
      rethrow;
    } finally {
      trace?.finish();
    }
  }

  @override
  ({Locator start, Locator end}) pageBounds(
    ChapterLayout layout,
    int pageIndex,
  ) {
    final slice = layout.page(pageIndex);
    return (
      start: layout.beginLocatorOf(slice),
      end: layout.endLocatorOf(slice),
    );
  }

  @override
  PageRef? pageOf(ChapterLayout layout, Locator locator) {
    final index = layout.pageIndexOf(locator);
    if (index == null) return null;
    return PageRef(chapterId: layout.chapterId, pageIndex: index);
  }

  @override
  List<Rect> selectionRects(
    ChapterLayout layout,
    int pageIndex,
    Locator from,
    Locator to, {
    Map<String, int>? chapterOrdinals,
  }) => selectionRectsForPage(
    layout: layout,
    pageIndex: pageIndex,
    from: from,
    to: to,
    chapterOrdinals: chapterOrdinals,
  );

  @override
  Locator? locatorAtPoint(
    ChapterLayout layout,
    int pageIndex,
    Offset position,
  ) => locatorAtPointInPage(
    layout: layout,
    pageIndex: pageIndex,
    position: position,
  );

  @override
  CaretGeometry? caretAt(
    ChapterLayout layout,
    int pageIndex,
    Locator locator, {
    required bool atEnd,
  }) => caretAtLocator(
    layout: layout,
    pageIndex: pageIndex,
    locator: locator,
    atEnd: atEnd,
  );

  @override
  Locator? pageEdge(
    ChapterLayout layout,
    int pageIndex, {
    required bool atEnd,
  }) => pageEdgeLocator(layout: layout, pageIndex: pageIndex, atEnd: atEnd);

  @override
  ({Locator start, Locator end})? sentenceRangeAtPoint(
    ChapterLayout layout,
    int pageIndex,
    Offset position,
  ) => sentenceRangeAtPointInPage(
    layout: layout,
    pageIndex: pageIndex,
    position: position,
  );

  /// 参数变化（字号、窗口尺寸等）后作废旧令牌并丢弃缓存
  @override
  void invalidateLayout({String? bookId}) {
    _current?.cancel();
    _current = null;
    _cache.invalidate(bookId: bookId);
    _measurements.clear();
  }
}
