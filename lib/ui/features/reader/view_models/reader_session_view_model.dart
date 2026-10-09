/// 阅读会话：一本书的当前章、当前页与真实排版结果（实现计划 S8/S9）。
///
/// 分工：
/// - 这里只管「这本书现在排到哪一页」，不保存业务数据（进度落盘在 S11）；
/// - 排版参数（字号/行高/段距/页边距/缩进/字体）由界面侧的 [ReaderState] 提供，
///   两者通过 [applyViewport] 对齐：参数或窗口尺寸一变就重排，并停在原来的句子上；
/// - 版式结果只放内存，参数变化会自然换缓存键（见 `LayoutCache`）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reader_session_state.dart';
import 'annotation_opening.dart';
import 'reader_view_model.dart';
import 'reader_settings_view_model.dart';
import 'automatic_reading.dart';
import 'reader_progress_return.dart';
import '../widgets/turn_trace.dart';

export 'reader_session_state.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/bookmark.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../../domain/repositories/reading_position_repository.dart';
import '../../../../domain/services/reader_engine.dart';
import '../../../../domain/services/toc_entry_index.dart';
import '../../../../engine/layout/chapter_layout.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/normalization/text_anchor.dart';
import '../../../../engine/parsers/epub/anchor_locator.dart';
import '../../../../engine/parsers/epub/toc_progress_entries.dart';

part 'reader_layout_coordinator.dart';
part 'reader_original_position.dart';
part 'reader_annotation_navigation.dart';
part 'reader_scroll_position.dart';
part 'reader_display_position.dart';
part 'reader_toc_navigation.dart';
part 'reader_progress_titles.dart';
part 'reader_scan_commit.dart';
part 'reader_image_navigation.dart';

class ReaderSessionNotifier extends AsyncNotifier<ReaderSession>
    with _ReaderLayoutCoordinator, _ReaderOriginalPosition, _ReaderAnnotationNavigation,
        _ReaderScrollPosition, _ReaderDisplayPosition, _ReaderTocNavigation {
  ReaderSessionNotifier(this.bookId);
  ReaderSession get _scanSession => state.requireValue;
  void _publishScan(ReaderSession session) => state = AsyncData(session);
  @override
  Annotation? _annotationTarget;
  @override
  Completer<void>? _annotationDone;
  @override
  Future<void>? _annotationTask;
  @override
  ({int chapter, double fraction, Completer<void> done})? _progressLanding;
  @override
  ({String chapterId, String? blockId, double progress, Completer<void> done})?
  _tocLanding;

  @override
  final String bookId;

  @override
  LayoutOptions? _options;
  int _positionToken = 0;
  @override
  ReadingPosition? _listeningRestore;
  @override
  final _restoreArrivals = <ReadingLayoutMode, Locator>{};
  @override
  Locator? _originalExact;
  @override
  Locator? _originalReportExact;
  @override
  double? _exactOriginalFraction;

  @override
  LayoutToken? _token;
  @override
  int _tokenVersion = 0;

  /// 当前排版模式（界面通过 [setLayoutMode] 告知）：换章与上报回填都按它决定。
  @override
  ReadingLayoutMode _mode = ReadingLayoutMode.simplified;
  ReadingLayoutMode get layoutMode => _mode;

  @override
  final _modePositions =
      <
        ReadingLayoutMode,
        ({Locator anchor, double fraction, String? signature})
      >{};
  @override
  final _modeArrivals = <ReadingLayoutMode, Locator>{};
  @override
  bool _awaitingModeArrival = false;
  @override
  String? _pendingOriginalText;

  /// 原书模式换章时的落点比例（0 = 章首、1 = 章末）；取一次即清
  @override
  double? _pendingOriginalFraction;
  @override
  String? _pendingOriginalAnchorId;

  /// 原书模式换章的落点标题（目录条目名）：比锚点准，见 [takeOriginalLandingTitle]
  @override
  String? _pendingOriginalTitle;

  /// 章内定位请求的序号：同一个位置连跳两次也要能生效
  @override
  int _jumpToken = 0;

  /// 原书模式换章跳转正在进行；拖动滑块期间会连续触发，只保留最后一次目标
  @override
  bool _originalJumpInFlight = false;
  @override
  ({int index, double fraction})? _queuedOriginalJump;

  /// 预取的下一章排版（用于翻页过渡时显示下一页）
  @override
  ChapterLayout? _nextChapterLayout;

  /// 预取的上一章排版（章首往回拖时显示上一章的最后一页）
  @override
  ChapterLayout? _previousChapterLayout;

  /// 上次退出时的位置：首次排版时按它落页，落页后清空
  @override
  Locator? _pendingAnchor;

  @override
  Future<ReaderSession> build() => traceTurnStep('load session', () async {
    ref.onDispose(() { ++_tokenVersion; _token?.cancel(); });
    _positionToken = ref
        .read(readingPositionCoordinatorProvider)
        .version(bookId);
    final books = ref.watch(bookRepositoryProvider);
    final contents = ref.watch(chapterContentRepositoryProvider);
    final book = await traceTurnStep('load book', () => books.findById(bookId));
    if (book == null || book.status != BookStatus.active) {
      throw const ReaderFailure('这本书已不在书架中');
    }
    final chapters = await traceTurnStep('load chapters', () => books.chaptersOf(bookId));
    if (chapters.isEmpty) {
      throw const ReaderFailure('这本书没有可阅读的正文，请重新导入');
    }
    // 初次打开时设置可能早于会话就绪，界面的变更监听不会再触发一次。
    // 在返回首帧数据前同步显示模式，原书的位置回报才能被正常接收。
    final settings = await traceTurnStep('load settings-font', () => ref.read(readerSettingsProvider(bookId).future));
    _mode = book.format == BookFormat.epub
        ? settings.settings.layoutMode
        : ReadingLayoutMode.simplified;
    // TXT 固定使用简化排版，即使全局选了“原书字体”，也准备实际文本字体。
    if (!_mode.isOriginal) await ref.read(selectedFontLoaderProvider)(settings.settings.fontFamily);
    final scrolling = settings.settings.pageTurnEffect == PageTurnEffect.scroll;
    // 打开即读：封面页、版权页这类没有正文的章节不占用首屏。
    // 这里只看章节索引里的字数（设计文档 6.3：书架与定位不读章节文件）。
    final start = chapters.indexWhere((c) => c.textLength > 0);
    var chapterIndex = start < 0 ? 0 : start;
    // 上次读到哪里就从哪里继续（设计文档 7.1 reading_positions）
    final stored = await ref
        .read(readingPositionRepositoryProvider)
        .load(bookId);
    final saved =
        await ref.read(prepareListeningReaderProvider)(bookId) ?? stored;
    final locator = saved?.locator;
    if (locator != null && locator.contentVersion == book.contentVersion) {
      final index = chapters.indexWhere((c) => c.id == locator.chapterId);
      if (index >= 0) {
        chapterIndex = index;
        _pendingAnchor = locator;
        if (saved!.source == ReadingPositionSource.listening) {
          _listeningRestore = saved;
          _originalExact = locator;
          _pendingOriginalFraction = 0;
        }
        // 原书模式的落点直接用存下来的**进度**：它就是上次上报的页比例
        // （页 / 页数），乘页数正好回到原来那一页。若由 Locator 现算，算出来的
        // 是字数比例——图片占版面不计字，比例偏小，落点会退到前一页；而落点
        // 页首又会被存成新位置，于是反复打开一次比一次往回退（用户反馈）。
        final landed = saved.source == ReadingPositionSource.listening
            ? null
            : ReaderSession.chapterFractionOf(
                saved.progress,
                chapters,
                book,
                index,
              );
        if (landed != null) _pendingOriginalFraction = landed;
      }
    }
    final opening = ref.read(annotationOpeningProvider.notifier).take(bookId);
    if (opening != null) {
      chapterIndex = chapters.indexWhere((c) => c.id == opening.start.chapterId);
      _annotationTarget = opening;
      _pendingAnchor = opening.start;
      _listeningRestore = null;
      _originalExact = opening.start;
      _pendingOriginalFraction = 0;
      _pendingOriginalText = null;
    }
    // 只读当前章正文；整书按需读取，不整本进内存
    final first = await traceTurnStep('load current-content', () => contents.chapter(bookId, chapters[chapterIndex]));
    // 目录跳转保存的是标题锚点；该标题可能在页中部。续读只按页比例上报
    // 会把标题前的上一章页首存回去，导致“下一章”的章名又倒退。
    final anchor = _pendingAnchor;
    if (anchor != null &&
        anchor.utf16Offset == 0 &&
        (_pendingOriginalFraction ?? 0) > 0) {
      for (final block in first.blocks) {
        if (block.id == anchor.blockId && block.kind == BlockKind.heading) {
          _pendingOriginalTitle = block.runs.map((run) => run.text).join();
          break;
        }
      }
    }
    return ReaderSession(
      book: book,
      chapters: chapters,
      chapterIndex: chapterIndex,
      content: first,
      scrolling: scrolling,
    );
  });

  Locator? get listeningStartAnchor {
    final anchor = state.value?.currentAnchor;
    return anchor == null ? null : _restoredPosition(anchor)?.locator ?? anchor;
  }

  bool _manualListening = false;
  Future<void>? _manualHandoff;

  /// 只由明确的用户翻页/跳转调用，布局与跟随回报不能自行取得保存权。
  @override
  Future<void> beginManualReading() async {
    await ref.read(automaticReadingProvider(bookId).notifier).discard();
    await beginAutomaticReading();
  }

  /// 自动阅读也需要取得位置保存权，但不能暂停它正在准备的开始命令。
  Future<void> beginAutomaticReading() => _manualHandoff ??= _beginManualReading()
      .whenComplete(() => _manualHandoff = null);

  Future<void> _beginManualReading() async {
    final coordinator = ref.read(readingPositionCoordinatorProvider);
    if (coordinator.owner(bookId) == ReadingPositionSource.listening ||
        coordinator.version(bookId) != _positionToken) {
      final service = ref.read(listeningServiceProvider);
      cancelSpeechFollow();
      await service.takeOverReading(bookId);
      if (!ref.mounted) return;
      cancelSpeechFollow();
      _manualListening = true;
    }
    _positionToken = coordinator.version(bookId);
    _clearRestoredPosition();
  }

  /// 把当前页首位置与全书进度写进阅读位置（翻页、换章、切后台时调用）。
  ///
  /// 位置是 `Locator`，与排版无关：改字号、换主题之后仍然指向同一句话；
  /// 进度是内容比例，逐页变化，书架直接显示它。
  @override
  Future<void> persist() async {
    final session = state.value;
    if (session == null) return;
    // 原书模式可能还没有简化模式的排版结果，这里不能按 isReady 卡住：
    // 只要有位置就写（位置从 currentAnchor 取，它认得两种模式）
    final anchor = session.currentAnchor;
    if (anchor == null) return;
    final coordinator = ref.read(readingPositionCoordinatorProvider);
    final position =
        _restoredPosition(anchor) ??
        ReadingPosition(locator: anchor, progress: session.bookProgress);
    // 多个位置上报可能紧挨着到达。串行写入并让调用方真正等到自己的写入完成，
    // 避免退出时旧写入最后完成、覆盖刚拖动或刚换章的位置。
    final token = _positionToken;
    await coordinator.save(
      position,
      token: token,
      source: ReadingPositionSource.visual,
    );
    if (ref.mounted &&
        _manualListening &&
        coordinator.accepts(bookId, token, ReadingPositionSource.visual)) {
      ref.read(listeningServiceProvider).updateReadingPosition(anchor);
    }
  }

  /// 目录按钮等待本次定位的画面确认，再保存真实位置。
  @override
  Future<void> waitForTocPosition() async {
    if (state.value?.scrolling == true) {
      await waitForScrollPosition();
    } else if (_mode.isOriginal) {
      final pending = _tocPresentation;
      if (pending != null) {
        try {
          await traceTurnStep('toc presented chapter=${pending.chapter}',
              () => pending.done.future.timeout(const Duration(seconds: 10)));
        } finally {
          if (identical(_tocPresentation, pending)) _tocPresentation = null;
        }
      }
    }
    await persist();
  }

  @override
  bool _matchesTocLanding(
    ReaderSession session,
    String chapterId,
    String? blockId,
    double progress,
  ) {
    final anchor = session.currentAnchor;
    if (anchor == null || anchor.chapterId != chapterId) return false;
    if (blockId != null) return anchor.blockId == blockId;
    return (session.contentProgress - progress).abs() <= kTocProgressEpsilon;
  }

  /// 返回阅读页或切后台前，等正在落位的操作结束，并确保最后位置已写入。
  Future<void> flushPendingPosition() async {
    await ref.read(flushListeningPositionProvider)();
    final pending = <Future<void>>[
      ?pendingScrollPosition,
      if (_progressLanding case final landing?) landing.done.future,
      if (_tocLanding case final landing?) landing.done.future,
    ];
    if (pending.isNotEmpty) {
      try {
        await Future.wait(pending).timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // WebView 异常时不能把用户锁在阅读页，超时后保存当前已确认的位置。
      }
    }
    await ref.read(automaticReadingProvider(bookId).notifier).flushPosition();
    await persist();
  }

  /// 翻到下一页；已在全书末尾时返回 [PageTurnResult.atBookEnd]。
  Future<PageTurnResult> nextPage() async {
    await beginManualReading();
    _clearRestoredPosition();
    final session = state.value;
    if (session == null || !session.isReady) return PageTurnResult.moved;
    if (session.pageIndex + 1 < session.pageCount) {
      state = AsyncData(session.copyWith(pageIndex: session.pageIndex + 1));
      unawaited(persist());
      return PageTurnResult.moved;
    }
    if (session.chapterIndex + 1 >= session.chapters.length) {
      return PageTurnResult.atBookEnd;
    }
    await _layoutChapter(
      chapterIndex: session.chapterIndex + 1,
      options: _options,
      anchor: null,
    );
    return PageTurnResult.moved;
  }

  /// 翻到上一页；已在全书开头时返回 [PageTurnResult.atBookStart]。
  Future<PageTurnResult> previousPage() async {
    await beginManualReading();
    _clearRestoredPosition();
    final session = state.value;
    if (session == null || !session.isReady) return PageTurnResult.moved;
    if (session.pageIndex > 0) {
      state = AsyncData(session.copyWith(pageIndex: session.pageIndex - 1));
      unawaited(persist());
      return PageTurnResult.moved;
    }
    if (session.chapterIndex == 0) return PageTurnResult.atBookStart;
    await _layoutChapter(
      chapterIndex: session.chapterIndex - 1,
      options: _options,
      anchor: null,
      // 进入上一章时落在它的最后一页，向前翻页才连续
      atChapterEnd: true,
    );
    return PageTurnResult.moved;
  }

  /// 跳到指定章节（目录跳转、上一章/下一章按钮）。
  @override
  Future<void> goToChapter(int index) async {
    await beginManualReading();
    _clearRestoredPosition();
    final session = state.value;
    if (session == null) return;
    if (index < 0 || index >= session.chapters.length) return;
    if (session.scrolling) {
      await requestScrollChapter(index);
      return;
    }
    if (index == session.chapterIndex) return;
    // 原书模式不做简化排版：切章 + 章首落点，正文由 WebView 画
    if (_mode.isOriginal) {
      await jumpToOriginalChapter(index, fraction: 0);
      await _flushQueuedOriginalJump();
      return;
    }
    await _layoutChapter(chapterIndex: index, options: _options, anchor: null);
  }

  /// 按章节 ID 跳转（目录里的章节带的是 ID，不是序号）
  Future<void> goToChapterId(String chapterId) async {
    final session = state.value;
    if (session == null) return;
    final index = session.chapters.indexWhere((c) => c.id == chapterId);
    if (index < 0) return;
    await goToChapter(index);
  }

  /// 跳到内容位置（书签、进度滑块、目录定位）。
  int _speechRequest = 0;
  void cancelSpeechFollow() => _speechRequest++;

  /// 跟随只替换显示状态；不保存页首、不启动翻页动画。同页直接返回。
  Future<void> followSpeech(Locator locator) async {
    final request = ++_speechRequest;
    final session = state.value;
    final options = _options;
    if (session == null) return;
    final index = session.chapters.indexWhere((c) => c.id == locator.chapterId);
    if (index < 0) return;
    if (session.scrolling) {
      requestScrollPosition(locator, animated: true);
      return;
    }
    if (_mode.isOriginal) {
      if (session.chapterIndex == index) return;
      final content = await ref
          .read(chapterContentRepositoryProvider)
          .chapter(bookId, session.chapters[index]);
      if (!ref.mounted || request != _speechRequest || !_mode.isOriginal) {
        return;
      }
      _originalExact = locator;
      _pendingOriginalFraction = 0;
      state = AsyncData(
        session.copyWith(
          chapterIndex: index,
          content: content,
          pageIndex: 0,
          clearOriginalPosition: true,
        ),
      );
      return;
    }
    if (options == null) return;
    var layout = session.layout;
    var content = session.content;
    if (layout == null || layout.chapterId != locator.chapterId) {
      content = await ref
          .read(chapterContentRepositoryProvider)
          .chapter(bookId, session.chapters[index]);
      if (request != _speechRequest || !ref.mounted) return;
      layout = await ref
          .read(readerEngineProvider)
          .layoutChapter(
            LayoutRequest(
              bookId: bookId,
              contentVersion: session.book.contentVersion,
              chapter: session.chapters[index],
              content: content,
              options: options,
            ),
          );
    }
    if (!ref.mounted ||
        request != _speechRequest ||
        _mode.isOriginal ||
        options != _options) {
      return;
    }
    final page = layout.pageIndexOf(locator);
    if (page == null ||
        (layout == session.layout && page == session.pageIndex)) {
      return;
    }
    state = AsyncData(
      ReaderSession(
        book: session.book,
        chapters: session.chapters,
        chapterIndex: index,
        content: content,
        layout: layout,
        pageIndex: page,
        viewportSignature: options.layoutSignature,
      ),
    );
  }

  @override
  Future<void> goToLocator(
    Locator locator, {
    bool restoringListening = false,
    bool manual = true,
  }) async {
    if (manual && !restoringListening) await beginManualReading();
    if (!restoringListening) _clearRestoredPosition();
    final session = state.value;
    if (session == null) return;
    final index = session.chapters.indexWhere((c) => c.id == locator.chapterId);
    if (index < 0) return;
    // 原书模式：把 Locator 折成章内比例交给宿主页
    if (session.scrolling) {
      requestScrollPosition(locator);
      return;
    }
    if (_mode.isOriginal) {
      final fraction = await _fractionOfLocatorIn(index, locator);
      if (fraction == null) return;
      await jumpToOriginalChapter(index, fraction: fraction);
      await _flushQueuedOriginalJump();
      return;
    }
    if (index == session.chapterIndex && session.layout != null) {
      final page = session.layout!.pageIndexOf(locator);
      if (page != null) {
        state = AsyncData(session.copyWith(pageIndex: page));
        if (manual && !restoringListening) await persist();
        return;
      }
    }
    await _layoutChapter(
      chapterIndex: index,
      options: _options,
      anchor: locator,
    );
  }

  /// 按百分比跳转（控制层进度滑块）。
  Future<void> goToProgress(
    double fraction, {
    bool waitForOriginal = false,
  }) async {
    await beginManualReading();
    _clearRestoredPosition();
    final session = state.value;
    if (session == null || session.chapters.isEmpty) return;
    final target = (bookTotalChars(session) * fraction.clamp(0.0, 1.0)).round();
    var consumed = 0;
    for (var i = 0; i < session.chapters.length; i++) {
      final length = session.chapters[i].textLength;
      if (consumed + length >= target || i == session.chapters.length - 1) {
        final within = (target - consumed).clamp(0, length).toInt();
        if (session.scrolling) {
          await requestScrollChapter(i,
              fraction: length == 0 ? 0 : within / length);
          if (waitForOriginal) {
            await waitForScrollPosition();
            await persist();
          }
          return;
        }
        // 原书模式：按章内比例跳（进度滑块拖动会连续触发，这里只下发一次定位）
        if (_mode.isOriginal) {
          final fraction = length <= 0 ? 0.0 : within / length;
          final previous = _progressLanding;
          if (previous != null && !previous.done.isCompleted) {
            previous.done.complete();
          }
          final landing = waitForOriginal
              ? (chapter: i, fraction: fraction, done: Completer<void>())
              : null;
          _progressLanding = landing;
          await jumpToOriginalChapter(i, fraction: fraction);
          await _flushQueuedOriginalJump();
          if (landing != null) {
            try {
              // 等真实落页确认；超时只报失败，不用固定延时掩盖闪回。
              await landing.done.future.timeout(const Duration(seconds: 10));
            } finally {
              if (identical(_progressLanding, landing)) _progressLanding = null;
            }
            await persist();
          }
          return;
        }
        if (i == session.chapterIndex && session.layout != null) {
          // 章内按同口径换算到页
          final page = _pageForChapterOffset(session.layout!, within);
          state = AsyncData(session.copyWith(pageIndex: page));
          return;
        }
        await _layoutChapter(
          chapterIndex: i,
          options: _options,
          anchor: null,
          chapterOffset: within,
        );
        return;
      }
      consumed += length;
    }
  }
}

/// 阅读会话 Provider：按书隔离，退出阅读页即释放（设计文档 4.2）。
final readerSessionProvider =
    AsyncNotifierProvider.family<ReaderSessionNotifier, ReaderSession, String>(
      ReaderSessionNotifier.new,
      isAutoDispose: true,
    );

/// 这本书的书签（最近加的在前）：加/删之后列表自动刷新。
final bookmarksProvider = StreamProvider.family<List<Bookmark>, String>((
  ref,
  bookId,
) {
  return ref.watch(annotationRepositoryProvider).watchBookmarks(bookId);
});

/// 这本书的高亮与笔记（最近改动的在前）：操作条据此判断这段选文是不是
/// 已经有标注，有就改成「编辑想法」，不新建重复记录（实现计划 N5）。
final annotationsProvider = StreamProvider.family<List<Annotation>, String>((
  ref,
  bookId,
) {
  return ref.watch(annotationRepositoryProvider).watchAnnotations(bookId);
});

/// 这本书的真实目录（导入时写进 `content/<版本>/manifest.json`）。
///
/// 不分卷的书是「一层叶子」，带卷的书是「卷 → 章」两层；读不出来时返回空表，
/// 界面降级为按章节平铺（设计文档 6.2）。
final bookTocProvider = FutureProvider.family<List<TocNode>, String>((
  ref,
  bookId,
) async {
  final book = await ref.watch(bookRepositoryProvider).findById(bookId);
  if (book == null) return const [];
  return ref
      .read(chapterContentRepositoryProvider)
      .toc(bookId, book.contentVersion);
});
