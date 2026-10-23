part of 'reader_session_view_model.dart';

/// 听书只更新显示位置；与手动导航分开记录请求及取消原因。
mixin _ReaderSpeechFollow
    on
        AsyncNotifier<ReaderSession>,
        _ReaderScrollPosition,
        _ReaderOriginalPosition {
  void _watchLayout(ChapterLayout layout);

  int _speechRequest = 0;
  ListeningFollowDiagnostics? _speechDiagnostics;
  void cancelSpeechFollow() {
    _speechRequest++;
    _speechDiagnostics?.step('sessionCancel', {'request': _speechRequest});
  }

  /// 跟随只替换显示状态；不保存页首、不启动翻页动画。同页直接返回。
  Future<void> followSpeech(
    Locator locator, {
    ListeningFollowDiagnostics? diagnostics,
  }) async {
    _speechDiagnostics = diagnostics;
    final request = ++_speechRequest;
    final session = state.value;
    final options = _options;
    void log(String event, [Map<String, Object?> details = const {}]) =>
        diagnostics?.step(event, {
          'request': request,
          'currentRequest': _speechRequest,
          'mounted': ref.mounted,
          ...details,
        });
    log('sessionBegin', {
      'hasSession': session != null,
      'hasOptions': options != null,
      'mode': _mode.name,
      'scrolling': session?.scrolling,
    });
    if (session == null) {
      log('sessionSkip', {'reason': 'noSession'});
      return;
    }
    final index = session.chapters.indexWhere((c) => c.id == locator.chapterId);
    if (index < 0) {
      log('sessionSkip', {'reason': 'unknownChapter'});
      return;
    }
    if (session.scrolling) {
      requestScrollPosition(locator, animated: true);
      log('scrollRequested', {'token': speechScrollToken});
      return;
    }
    if (_mode.isOriginal) {
      if (session.chapterIndex == index) {
        log('sessionSkip', {'reason': 'sameOriginalChapter'});
        return;
      }
      log('contentBegin', {'targetChapter': index});
      final content = await ref
          .read(chapterContentRepositoryProvider)
          .chapter(bookId, session.chapters[index]);
      if (!ref.mounted || request != _speechRequest || !_mode.isOriginal) {
        log('sessionDiscard', {'stage': 'originalContent'});
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
      log('chapterPublished', {'chapter': index});
      return;
    }
    if (options == null) {
      log('sessionSkip', {'reason': 'noOptions'});
      return;
    }
    var layout = session.layout;
    var content = session.content;
    if (layout == null || layout.chapterId != locator.chapterId) {
      log('contentBegin', {'targetChapter': index});
      content = await ref
          .read(chapterContentRepositoryProvider)
          .chapter(bookId, session.chapters[index]);
      if (request != _speechRequest || !ref.mounted) {
        log('sessionDiscard', {'stage': 'content'});
        return;
      }
      log('layoutBegin');
      layout = await ref
          .read(readerEngineProvider)
          .layoutWindow(
            LayoutRequest(
              bookId: bookId,
              contentVersion: session.book.contentVersion,
              chapter: session.chapters[index],
              content: content,
              options: options,
            ),
            target: locator,
          );
    }
    if (!ref.mounted ||
        request != _speechRequest ||
        _mode.isOriginal ||
        options != _options) {
      log('sessionDiscard', {
        'stage': 'layout',
        'sameOptions': options == _options,
      });
      return;
    }
    log('ensureTargetBegin');
    layout = await layout.ensureTarget(locator);
    if (!ref.mounted || request != _speechRequest) {
      log('sessionDiscard', {'stage': 'ensureTarget'});
      return;
    }
    final page = layout.pageIndexOf(locator);
    if (page == null ||
        (layout == session.layout && page == session.pageIndex)) {
      log('sessionSkip', {
        'reason': page == null ? 'pageMissing' : 'samePage',
        'page': page,
      });
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
    _watchLayout(layout);
    log('pagePublished', {'chapter': index, 'page': page});
  }
}
