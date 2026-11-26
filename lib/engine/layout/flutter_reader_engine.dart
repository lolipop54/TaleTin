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

import '../../domain/models/book.dart';
import '../../domain/models/exact_page_count.dart';
import '../../domain/models/locator.dart';
import '../../domain/services/reader_engine.dart';
import '../selection/selection_rects.dart';
import 'chapter_layout.dart';
import 'layout_cache.dart';
import 'block_measurement_cache.dart';
import 'english_hyphenation.dart';
import 'layout_options.dart';
import '../normalization/content_fingerprint.dart';

class FlutterReaderEngine extends ReaderEngine {
  FlutterReaderEngine({
    LayoutCache? cache,
    this.checkpoints,
    this.prepareFonts,
    this.recordPages,
    this.lookupPages,
  }) : _cache = cache ?? LayoutCache();
  final void Function(Book, LayoutOptions, ExactPageCount)? recordPages;

  final Future<int?> Function(Book, LayoutOptions, int, int, int, int)?
  lookupPages;

  Future<int?> Function(int, int, int)? _knownWindows(LayoutRequest request) {
    final book = request.book, options = request.options, lookup = lookupPages;
    final chapter = request.chapter.ordinal;
    if (book == null ||
        lookup == null ||
        (book.format != BookFormat.txt && request.sections == null)) {
      return null;
    }
    return (window, offset, windows) =>
        lookup(book, options, chapter, window, offset, windows);
  }

  void Function(ExactPageCount)? _reporter(LayoutRequest request) {
    final book = request.book, options = request.options, record = recordPages;
    if (record == null ||
        book == null ||
        (book.format.usesOriginalWebView &&
            options.settings.layoutMode.isOriginal) ||
        book.format == BookFormat.pdf) {
      return null;
    }
    return (part) => record(book, options, part);
  }

  final LayoutCheckpointStore? checkpoints;
  final PreparePublicationFonts? prepareFonts;

  Future<LayoutOptions>? _fontPreparation(LayoutRequest request) {
    final options = request.options;
    return options.settings.useBookFontsInSimplified
        ? prepareFonts?.call(request.bookId, request.content, options)
        : null;
  }

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
    if (!ReaderDeliveryExperiments.incremental && request.sections == null) {
      return layoutChapter(request, token: token);
    }
    final task = await _taskFor(request);
    return task.ensure(
      target: target,
      chapterOffset: request.chapterOffset,
      atEnd: atEnd,
      token: token,
      lookAhead: request.targetFirst ? 0 : 4,
      foregroundBudgetUs: request.targetFirst ? 4000 : 2000,
      deferCheckpointEncoding: request.targetFirst,
      allowPageRestart: request.allowPageRestart,
    );
  }

  @override
  Future<int?> verifiedChapterTail(
    LayoutRequest request,
    String blockId, {
    LayoutToken? token,
  }) async {
    final task = await _taskFor(request);
    return task.verifiedChapterTail(blockId, token);
  }

  Future<ChapterLayoutTask> _taskFor(LayoutRequest request) async {
    final revision = (_allInvalidation, _bookInvalidation[request.bookId] ?? 0);
    final sections = request.sections;
    final preparation = sections == null ? _fontPreparation(request) : null;
    final options = preparation == null ? request.options : await preparation;
    final digest = sections == null
        ? await traceReaderWork(
            'layout.content_identity',
            () => ContentFingerprint.of(request.content),
          )
        : ('chapter-sections', sections.identity);
    // 核对实际正文摘要与所有使用字号的精确缩放值，相同正文重新解码仍命中。
    final key = (
      revision,
      request.bookId,
      request.contentVersion,
      request.chapter.id,
      digest,
      options.chapterSignature,
      options.contentSize,
    );
    var task = _tasks.remove(key);
    if (task == null) {
      final opening = _opening[key] ??= _createTask(request, options);
      try {
        task = await opening;
      } finally {
        if (identical(_opening[key], opening)) _opening.remove(key);
      }
    }
    if (revision !=
        (_allInvalidation, _bookInvalidation[request.bookId] ?? 0)) {
      task.dispose(reason: LayoutCancellationReason.layoutInvalidated);
      throw const LayoutCancelled(LayoutCancellationReason.layoutInvalidated);
    }
    _tasks[key] = task;
    // 不能回收仍在显示或正在处理前台请求的任务；跳转期间可暂时超过三个。
    while (_tasks.length > 3) {
      final oldest = _tasks.keys
          .where((k) => k != key && !_tasks[k]!.isInUse)
          .firstOrNull;
      if (oldest == null) break;
      _tasks
          .remove(oldest)
          ?.dispose(reason: LayoutCancellationReason.cacheEvicted);
    }
    return task;
  }

  Future<ChapterLayoutTask> _createTask(
    LayoutRequest request,
    LayoutOptions options,
  ) async {
    final sections = request.sections;
    if (sections != null) {
      return ChapterLayoutTask(
        bookId: request.bookId,
        contentVersion: request.contentVersion,
        chapter: request.chapter,
        content: null,
        options: options,
        indexedSections: sections,
        prepareSectionOptions:
            prepareFonts == null || !options.settings.useBookFontsInSimplified
            ? null
            : (body) => prepareFonts!(request.bookId, body, options),
        onExactPages: _reporter(request),
        knownWindow: _knownWindows(request),
        measurementCache: _measurements,
      );
    }
    // 长 TXT 每次只量目标附近的段落，既有整章断点的页边界不能混用。
    final store =
        ReaderDeliveryExperiments.checkpoint &&
            !ChapterLayoutTask.usesTxtWindows(
              request.chapter,
              request.content,
              options,
            )
        ? checkpoints
        : null;
    await EnglishHyphenation.prepare();
    final exact =
        '${EnglishHyphenation.fingerprint}|'
        '${request.content.pdfPage == null ? '' : 'pdf-without-page-heading-1|'}'
        '${request.contentVersion}|${request.chapter.contentPath}|'
        '${options.chapterSignature}|${options.contentSize.width}|'
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
      onExactPages: _reporter(request),
      knownWindow: _knownWindows(request),
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
      readPageWindow:
          key == null ||
              !ReaderDeliveryExperiments.checkpointDemand ||
              request.content.pdfPage != null ||
              options.settings.layoutMode.isOriginal
          ? null
          : (target, cursor) => store!.read(
              request.bookId,
              key,
              throughCursor: cursor,
              nearPage: target,
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
    if (request.sections != null) {
      return layoutWindow(request, token: token);
    }
    final trace = ReaderWorkTrace.start('layout.request', {
      'chapter': request.chapter.ordinal,
      'cancellable': token != null,
    });
    try {
      final preparation = _fontPreparation(request);
      final options = preparation == null ? request.options : await preparation;
      if (token?.isCancelled == true) throw const LayoutCancelled();
      final key = LayoutCache.keyFor(
        bookId: request.bookId,
        contentVersion: request.contentVersion,
        chapterId: request.chapter.id,
        layoutSignature: options.chapterSignature,
      );
      final cached = _cache.get(key);
      trace?.details['hit'] = cached != null;
      if (cached != null) {
        _recordCompleteChapter(request, options, cached);
        return cached;
      }

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
      _recordCompleteChapter(request, options, layout);
      return layout;
    } catch (error) {
      trace?.finish(status: error.runtimeType.toString());
      rethrow;
    } finally {
      trace?.finish();
    }
  }

  void _recordCompleteChapter(
    LayoutRequest request,
    LayoutOptions options,
    ChapterLayout layout,
  ) {
    final report = _reporter(request);
    if (report == null) return;
    final chapter = request.chapter, body = request.content;
    // 整章 TXT 与长章分节的页首不同。带前置插图的旧 TXT 也可能在后面才有章题，
    // 两个入口对这种旧正文的补题位置有差异，只交接两者版面相同的章。
    if (ChapterLayoutTask.usesTxtWindows(chapter, body, options)) return;
    if (options.insertChapterTitle) {
      final title = ChapterLayout.chapterTitleBlockIndex(body, chapter.title);
      if (title != null && title > 0) return;
    }
    report((
      chapter: chapter.ordinal,
      window: -1,
      offset: 0,
      windows: 1,
      pages: layout.pageCount,
    ));
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
  Future<({Locator start, Locator end})?> initialSelectionAtPoint(
    ChapterLayout layout,
    int pageIndex,
    Offset position,
  ) => initialSelectionAtPointInPage(
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
      task.dispose(reason: LayoutCancellationReason.layoutInvalidated);
      return true;
    });
  }
}
