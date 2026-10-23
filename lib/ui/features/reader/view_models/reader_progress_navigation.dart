part of 'reader_session_view_model.dart';

/// 百分比先确定正文目标，再交给当前版式落页。
extension _ReaderProgressNavigation on ReaderSessionNotifier {
  /// 按百分比跳转（控制层进度滑块）。
  Future<void> _goToProgress(
    double fraction, {
    bool waitForOriginal = false,
  }) async {
    cancelProgressNavigation();
    final request = _progressRequest;
    await traceReaderWork('reader.progress.stop_automatic', beginManualReading);
    if (!_sessionRef.mounted || request != _progressRequest) return;
    _clearRestoredPosition();
    final session = _progressSession;
    if (session == null || session.chapters.isEmpty) return;
    final target = (bookTotalChars(session) * fraction.clamp(0.0, 1.0)).round();
    var consumed = 0;
    for (var i = 0; i < session.chapters.length; i++) {
      final length = session.chapters[i].textLength;
      if (consumed + length >= target || i == session.chapters.length - 1) {
        final within = (target - consumed).clamp(0, length).toInt();
        if (session.scrolling) {
          await traceReaderWork(
            'reader.progress.scroll_request',
            () => requestScrollChapter(
              i,
              fraction: length == 0 ? 0 : within / length,
            ),
          );
          if (waitForOriginal) {
            await traceReaderWork(
              'reader.progress.scroll_landing',
              waitForScrollPosition,
            );
            await traceReaderWork('reader.progress.persist', persist);
          }
          return;
        }
        if (_mode.isOriginal && ReaderDeliveryExperiments.contentTarget) {
          final chapterRequest = ++_originalChapterRequest;
          if (session.book.format.usesOriginalWebView && ReaderDeliveryExperiments.originalPriority &&
              length >= 64 * 1024 &&
              i != session.chapterIndex) {
            _sessionRef
                .read(originalLayoutProvider(bookId))
                .value
                ?.prepareProgressChapter
                ?.call(i, length <= 0 ? 0 : within / length);
          }
          final content = await _contentFor(session.chapters[i]);
          if (!_sessionRef.mounted ||
              request != _progressRequest ||
              chapterRequest != _originalChapterRequest ||
              content == null) {
            if (request == _progressRequest) {
              cancelOriginalProgressPreparation?.call();
            }
            return;
          }
          final locator = locatorForFraction(
            content: content,
            bookId: bookId,
            contentVersion: session.book.contentVersion,
            chapterId: session.chapters[i].id,
            fraction: length <= 0 ? 0 : within / length,
          );
          if (locator == null) {
            cancelOriginalProgressPreparation?.call();
            return;
          }
          final previous = _contentProgressLanding;
          if (previous != null && !previous.done.isCompleted) {
            previous.done.complete();
          }
          final landing = (
            request: request,
            target: locator,
            done: Completer<void>(),
          );
          _contentProgressLanding = waitForOriginal ? landing : null;
          final moved = await jumpToOriginalChapter(
            i,
            fraction: length <= 0 ? 0 : within / length,
            exact: locator,
            preparedContent: content,
          );
          if (!moved || request != _progressRequest) return;
          if (waitForOriginal) {
            try {
              await traceReaderWork(
                'reader.progress.wait_content_landing',
                () => landing.done.future.timeout(const Duration(seconds: 10)),
              );
            } finally {
              if (identical(_contentProgressLanding, landing)) {
                _contentProgressLanding = null;
              }
            }
            if (request == _progressRequest) await persist();
          }
          return;
        }
        // 原书模式：按章内比例跳（进度滑块拖动会连续触发，这里只下发一次定位）
        if (_mode.isOriginal) {
          final fraction = length <= 0 ? 0.0 : within / length;
          if (readerWorkTraceEnabled) {
            ReaderWorkTrace.start('reader.progress.target', {
              'bookId': bookId,
              'fromChapter': session.chapterIndex,
              'targetChapter': i,
              'chapterTextLength': length,
              'chapterFraction': fraction,
              'waitForOriginal': waitForOriginal,
              'parallelEligible':
                  FirstSeekExperiments.parallelChapter &&
                  length >= 64 * 1024 &&
                  i != session.chapterIndex,
            })?.finish();
          }
          final previous = _progressLanding;
          if (previous != null && !previous.done.isCompleted) {
            previous.done.complete();
          }
          final landing = waitForOriginal
              ? (chapter: i, fraction: fraction, done: Completer<void>())
              : null;
          _progressLanding = landing;
          // 短章读取很快，提前挂载反而增加一轮帧调度；只并行读取较慢的大章。
          if (session.book.format.usesOriginalWebView && FirstSeekExperiments.parallelChapter &&
              length >= 64 * 1024 &&
              i != session.chapterIndex) {
            _sessionRef
                .read(originalLayoutProvider(bookId))
                .value
                ?.prepareProgressChapter
                ?.call(i, fraction);
          }
          await traceReaderWork(
            'reader.progress.switch_chapter',
            () => jumpToOriginalChapter(i, fraction: fraction),
          );
          if (landing != null) {
            try {
              // 等真实落页确认；超时只报失败，不用固定延时掩盖闪回。
              await traceReaderWork(
                'reader.progress.wait_landing',
                () => landing.done.future.timeout(const Duration(seconds: 10)),
              );
            } finally {
              if (identical(_progressLanding, landing)) _progressLanding = null;
            }
            await traceReaderWork('reader.progress.persist', persist);
          }
          return;
        }
        if (!ReaderDeliveryExperiments.contentTarget &&
            i == session.chapterIndex &&
            session.layout != null) {
          // 章内按同口径换算到页
          final page = _pageForChapterOffset(session.layout!, within);
          _publishScan(session.copyWith(pageIndex: page));
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
