/// [ReaderEngine] 的 Flutter 实现：把测量、分页、缓存装配起来。
///
/// 它只负责「同一份参数进来，同一份排版出去」，并做两件事：
/// 1. 命中缓存直接返回，不重复测量；
/// 2. 每次排版发一个令牌，参数变化或切章后旧令牌作废，过期结果不上屏。
library;

import 'dart:async';
import 'dart:ui' show Offset, Rect;

import '../../core/diagnostics/reader_work_trace.dart';
import '../../core/diagnostics/reader_delivery_experiments.dart';
import '../../domain/services/layout_checkpoint_store.dart';

import '../../domain/models/locator.dart';
import '../../domain/services/reader_engine.dart';
import '../selection/selection_rects.dart';
import 'chapter_layout.dart';
import 'layout_cache.dart';
import 'block_measurement_cache.dart';
import 'english_hyphenation.dart';
import '../normalization/content_fingerprint.dart';

class FlutterReaderEngine implements ReaderEngine {
  FlutterReaderEngine({LayoutCache? cache, this.checkpoints})
    : _cache = cache ?? LayoutCache();
  final LayoutCheckpointStore? checkpoints;

  final LayoutCache _cache;
  final _measurements = BlockMeasurementCache();
  final _tasks = <Object, ChapterLayoutTask>{};
  final _opening = <Object, Future<ChapterLayoutTask>>{};
  int _allInvalidation = 0;
  final _bookInvalidation = <String, int>{};
  int _version = 0;
  LayoutToken? _current;

  /// 当前生效的排版令牌（参数变化时作废上一个）
  LayoutToken get currentToken => _current ??= LayoutToken(++_version);

  @override
  Future<ChapterLayout> layoutWindow(
    LayoutRequest request, {
    Locator? target,
    bool atEnd = false,
    LayoutToken? token,
  }) async {
    if (!ReaderDeliveryExperiments.incremental) {
      return layoutChapter(request, token: token);
    }
    final options = request.options;
    final revision = (_allInvalidation, _bookInvalidation[request.bookId] ?? 0);
    final digest = await traceReaderWork(
      'layout.content_identity',
      () => ContentFingerprint.of(request.content),
    );
    // 核对实际正文摘要与所有使用字号的精确缩放值，相同正文重新解码仍命中。
    final key = (
      revision,
      request.bookId,
      request.contentVersion,
      request.chapter.id,
      digest,
      options.layoutSignature,
      options.contentSize,
    );
    var task = _tasks.remove(key);
    if (task == null) {
      final future = _opening[key] ??= _createTask(request);
      try {
        task = await future;
      } finally {
        if (identical(_opening[key], future)) _opening.remove(key);
      }
    }
    if (revision !=
        (_allInvalidation, _bookInvalidation[request.bookId] ?? 0)) {
      task.dispose();
      throw const LayoutCancelled();
    }
    _tasks[key] = task;
    // 不能回收仍在显示或正在处理前台请求的任务；跳转期间可暂时超过三个。
    while (_tasks.length > 3) {
      final oldest = _tasks.keys
          .where((k) => k != key && !_tasks[k]!.isInUse)
          .firstOrNull;
      if (oldest == null) break;
      _tasks.remove(oldest)?.dispose();
    }
    return task.ensure(target: target, atEnd: atEnd, token: token);
  }

  Future<ChapterLayoutTask> _createTask(LayoutRequest request) async {
    final store = ReaderDeliveryExperiments.checkpoint ? checkpoints : null;
    final options = request.options;
    await EnglishHyphenation.prepare();
    final exact =
        '${EnglishHyphenation.fingerprint}|'
        '${request.content.pdfPage == null ? '' : 'pdf-without-page-heading-1|'}'
        '${request.contentVersion}|${request.chapter.contentPath}|'
        '${options.layoutSignature}|${options.contentSize.width}|'
        '${options.contentSize.height}|${[for (var n = 1; n <= options.settings.fontSize + 8; n++) options.textScaler.scale(n.toDouble())]}';
    final key = await store?.identity(
      bookId: request.bookId,
      title: request.chapter.title,
      content: request.content,
      layout: exact,
      fontFamily: options.settings.fontFamily,
    );
    final task = ChapterLayoutTask(
      bookId: request.bookId,
      contentVersion: request.contentVersion,
      chapter: request.chapter,
      content: request.content,
      options: options,
      measurementCache: _measurements,
      onCheckpoint: key == null
          ? null
          : (data) {
              unawaited(store!.write(request.bookId, key, data));
            },
      readCheckpoint: key == null || !ReaderDeliveryExperiments.checkpointDemand
          ? null
          : (cursor, after) => store!.read(
              request.bookId,
              key,
              throughCursor: cursor,
              afterBlocks: after,
            ),
    );
    if (key != null && !ReaderDeliveryExperiments.checkpointDemand) {
      final cached = await store!.read(request.bookId, key);
      if (cached != null) task.restoreCheckpoint(cached);
    }
    ReaderWorkTrace.start('layout.checkpoint', {
      'chapter': request.chapter.ordinal,
      'enabled': store != null,
      'knownIdentity': key != null,
      'deferredRead': key != null,
    })?.finish();
    return task;
  }

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
    if (bookId == null) {
      _allInvalidation++;
    } else {
      _bookInvalidation.update(bookId, (v) => v + 1, ifAbsent: () => 1);
    }
    _current?.cancel();
    _current = null;
    _cache.invalidate(bookId: bookId);
    _measurements.clear();
    _tasks.removeWhere((_, task) {
      if (bookId != null && task.bookId != bookId) return false;
      task.dispose();
      return true;
    });
  }
}
