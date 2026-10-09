part of 'reader_session_view_model.dart';

mixin _ReaderTocNavigation
    on
        AsyncNotifier<ReaderSession>,
        _ReaderOriginalPosition,
        _ReaderScrollPosition {
  Future<void> beginManualReading();
  Future<void> goToChapter(int index);
  Future<void> waitForTocPosition();

  int _tocPresentationToken = 0;
  ({int token, int chapter, Completer<void> done})? _tocPresentation;

  int? get originalTocPresentationToken => _tocPresentation?.token;

  /// 目录目标已定位、原生画面已绘制、真实位置已回报，才能撤去跳转遮盖。
  /// 页首可能是标题前的图片或正文，不能要求它等于目录标题。
  void completeOriginalTocPresentation(int? token, int chapter) {
    final pending = _tocPresentation;
    if (pending != null && pending.token == token &&
        pending.chapter == chapter && !pending.done.isCompleted) {
      pending.done.complete();
    }
  }

  /// 从目录跳转：记下最近一次跳转前的位置，供正文中的返回面板使用。
  ///
  /// [rememberReturn] 为 false 时不记「刚才位置」——「上一章/下一章」按钮也走
  /// 这里（同一文件内的章要靠锚点定位），但按钮不是目录跳转，不该留下返回点。
  Future<void> goToChapterFromToc(
    String chapterId, {
    String? title,
    String? anchorId,
    bool rememberReturn = true,
  }) => rememberReturn
      ? ref
            .read(readerProgressReturnProvider(bookId).notifier)
            .jump(
              () async { await _goToChapterFromToc(
                chapterId,
                title: title,
                anchorId: anchorId,
              ); await waitForTocPosition(); },
            )
      : _goToChapterFromToc(chapterId, title: title, anchorId: anchorId);

  Future<void> _goToChapterFromToc(
    String chapterId, {
    String? title,
    String? anchorId,
  }) async {
    await beginManualReading();
    _clearRestoredPosition();
    final session = state.value;
    if (session == null || (!_mode.isOriginal && !session.isReady)) return;
    final index = session.chapters.indexWhere((c) => c.id == chapterId);
    if (index < 0) return;
    if ((session.scrolling || !_mode.isOriginal) &&
        session.book.format == BookFormat.epub &&
        anchorId?.isNotEmpty == true) {
      final target = await scrollLinkAnchor(index, anchorId!);
      if (target != null) {
        await goToLocator(target);
        return;
      }
    }
    final landingTitle = title?.trim();
    final hasTitle = landingTitle?.isNotEmpty == true;
    if (_mode.isOriginal && !session.scrolling) {
      final previous = _tocPresentation;
      if (previous != null && !previous.done.isCompleted) previous.done.complete();
      _tocPresentation = (token: ++_tocPresentationToken,
          chapter: index, done: Completer<void>());
      final linkAnchor = anchorId?.isNotEmpty == true ? anchorId : null;
      // 带 #fragment 的目录链接按锚点定位，标题只在这个锚点损坏时兜底；
      // 不带片段的链接表示章节文件首页，不能拿目录名去正文里搜索同名标题。
      final fallbackTitle = linkAnchor == null || !hasTitle
          ? null
          : landingTitle;
      if (index == session.chapterIndex) {
        _requestOriginalJump(0, anchorId: linkAnchor, title: fallbackTitle);
        return;
      }
      _pendingOriginalAnchorId = linkAnchor;
      _pendingOriginalTitle = fallbackTitle;
      if (!await jumpToOriginalChapter(index, fraction: 0)) {
        _tocPresentation = null;
        throw StateError('目录目标未能换章');
      }
      return;
    }
    // 一份 XHTML 内可以有上百个 NCX 锚点。简化正文没有保留 DOM id，
    // 用同名标题块还原稳定 Locator；原书模式再由 Locator 换算章内落点。
    final normalizedTitle = title?.trim();
    if (normalizedTitle?.isNotEmpty == true) {
      final chapter = session.chapters[index];
      final content = await ref
          .read(chapterContentRepositoryProvider)
          .chapter(bookId, chapter);
      for (final block in content.blocks) {
        final text = block.runs.map((run) => run.text).join().trim();
        final txtTarget =
            session.book.format == BookFormat.txt &&
            anchorId == 'gt-txt:${block.id}';
        if ((!txtTarget && block.kind != BlockKind.heading) ||
            text != normalizedTitle) {
          continue;
        }
        await goToLocator(
          Locator(
            bookId: bookId,
            contentVersion: session.book.contentVersion,
            chapterId: chapter.id,
            blockId: block.id,
            utf16Offset: 0,
            exact: text.length <= kLocatorExactLimit
                ? text
                : text.substring(0, kLocatorExactLimit),
            resourceHref: chapter.href,
          ),
        );
        return;
      }
    }
    if (index == session.chapterIndex && !session.scrolling) {
      // TXT章题通常只存在章节索引里；点当前章也应回到章首，不能直接忽略。
      await goToLocator(session.layout!.startLocator);
      return;
    }
    await goToChapter(index);
  }
}
