part of 'reader_session_view_model.dart';

/// PDF显示器只在原页实际绘制后提交；进度、书签与退出仍使用同一会话保存入口。
extension PdfReaderPosition on ReaderSessionNotifier {
  Future<void> commitPdfPosition(
    int index, {
    double y = 0,
    Locator? exact,
    int? scrollToken,
    bool atEnd = false,
  }) async {
    final before = _progressSession;
    if (before == null ||
        before.book.format != BookFormat.pdf ||
        !_mode.isOriginal) {
      return;
    }
    final chapter = before.chapters[index];
    final content = before.content?.chapterId == chapter.id
        ? before.content!
        : await _sessionRef
              .read(chapterContentRepositoryProvider)
              .chapter(bookId, chapter, textOnly: true);
    if (!_sessionRef.mounted || !_mode.isOriginal) return;
    final current = _progressSession!;
    if (current.scrolling && scrollToken != current.scrollJump?.token) return;
    final locator =
        exact ??
        content.pdfPage!.anchorAt(
          content,
          bookId,
          chapter.id,
          y,
          contentVersion: current.book.contentVersion,
        );
    _publishPdfSession(
      current.copyWith(
        chapterIndex: index,
        pdfAtEnd: atEnd,
        content: content,
        originalAnchor: locator,
        originalFraction: fractionOfLocator(
          content: content,
          bookId: bookId,
          contentVersion: current.book.contentVersion,
          chapterId: chapter.id,
          locator: locator,
        ),
        originalContentProgress: true,
        scrollAnchor: locator,
      ),
    );
    reportDisplayArrival(locator);
    reportOriginalContentArrival(locator);
    if (_scrollLanding case final pending? when !pending.isCompleted) {
      pending.complete();
    }
    _scrollLanding = null;
    if (_tocLanding case final pending? when !pending.done.isCompleted) {
      pending.done.complete();
    }
    completeOriginalTocPresentation(originalTocPresentationToken, index);
    if (_progressLanding case final pending? when !pending.done.isCompleted) {
      pending.done.complete();
    }
    await persist();
  }
}
