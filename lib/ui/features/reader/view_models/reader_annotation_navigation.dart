part of 'reader_session_view_model.dart';

/// 笔记定位沿用同一个阅读会话与位置写入入口。
mixin _ReaderAnnotationNavigation
    on AsyncNotifier<ReaderSession>, _ReaderOriginalPosition {
  Annotation? get _annotationTarget;
  set _annotationTarget(Annotation? value);
  Completer<void>? get _annotationDone;
  set _annotationDone(Completer<void>? value);
  Future<void>? get _annotationTask;
  set _annotationTask(Future<void>? value);
  Future<void> beginManualReading();
  Annotation? get annotationTarget => _annotationTarget;

  void completeAnnotationLanding() {
    final done = _annotationDone;
    if (done != null && !done.isCompleted) done.complete();
    if (done == null) _annotationTarget = null;
  }

  Future<void> goToAnnotation(Annotation note, {bool persistRelocation = true}) =>
      _annotationTask ??= _goToAnnotation(note, persistRelocation)
          .whenComplete(() => _annotationTask = null);

  Future<void> _goToAnnotation(Annotation note, bool persistRelocation) async {
    if (_annotationDone != null) return;
    // 搜索只复用准确落点流程，临时范围即使重新核对也绝不能写成笔记。
    final located = persistRelocation
        ? await ref.read(prepareAnnotationProvider)(note)
        : await ref.read(annotationLocatorProvider).resolve(note);
    if (!ref.mounted) return;
    await beginManualReading();
    final session = state.value;
    if (session == null) return;
    final vm = ref.read(readerProvider.notifier);
    vm.clearSelection();
    _annotationTarget = located;
    try {
      if (session.scrolling) {
        final done = _annotationDone = Completer<void>();
        await goToLocator(located.start, manual: false);
        await done.future.timeout(const Duration(seconds: 10));
      } else if (_mode.isOriginal) {
        final index = session.chapters.indexWhere(
          (c) => c.id == located.start.chapterId,
        );
        final content = await ref
            .read(chapterContentRepositoryProvider)
            .chapter(bookId, session.chapters[index]);
        if (!ref.mounted) return;
        final done = _annotationDone = Completer<void>();
        _originalExact = located.start;
        // 同章请求直接消费 DOM 锚点，不留下会在下次重排生效的章首比例。
        _pendingOriginalFraction = index == session.chapterIndex ? null : 0;
        _pendingOriginalText = null;
        _pendingOriginalAnchorId = null;
        _pendingOriginalTitle = null;
        state = AsyncData(
          session.copyWith(
            chapterIndex: index,
            content: content,
            clearOriginalPosition: index != session.chapterIndex,
            originalJump: index == session.chapterIndex
                ? (
                    token: ++_jumpToken,
                    fraction: 0.0,
                    anchorId: null,
                    title: null,
                  )
                : null,
          ),
        );
        await done.future.timeout(const Duration(seconds: 10));
      } else {
        await goToLocator(located.start, manual: false);
        if (!ref.mounted) return;
      }
      if (!ref.mounted) return;
      vm.closePanel();
      await persist();
    } finally {
      _annotationDone = null;
      _annotationTarget = null;
    }
  }
}
