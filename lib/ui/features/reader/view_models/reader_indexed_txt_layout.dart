part of 'reader_session_view_model.dart';

/// 只读取目标所属的正文段。普通短章和无法安全切开的内容仍走整章入口。
Future<ChapterLayout?> _layoutIndexedChapter(
  Ref ref,
  String bookId,
  ReaderSession session,
  int index,
  LayoutOptions options, {
  Locator? target,
  int? chapterOffset,
  bool atEnd = false,
  bool targetFirst = false,
  LayoutToken? token,
}) async {
  final chapter = session.chapters[index];
  if (options.settings.layoutMode.isOriginal) return null;
  final source = await ref
      .read(chapterContentRepositoryProvider)
      .chapterSectionsForLayout(bookId, chapter, session.book.format);
  if (!ref.mounted || token?.isCancelled == true) {
    throw const LayoutCancelled();
  }
  if (source == null) return null;
  final layout = await ref
      .read(readerEngineProvider)
      .layoutWindow(
        LayoutRequest.sections(
          book: session.book,
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapter: chapter,
          source: source,
          options: options,
          targetFirst:
              targetFirst ||
              (chapterOffset != null &&
                  options.settings.spreadEnabled &&
                  session.book.format.usesOriginalWebView),
          chapterOffset: target == null ? chapterOffset : null,
        ),
        target: target,
        atEnd: atEnd,
        token: token,
      );
  if (!layout.isEmpty) return layout;
  // 作者样式可能隐藏整个段，取相邻的可见正文再交付页面。
  final next = await layout.adjacentPage(layout.firstPage, forward: !atEnd);
  if (next != null) return next.layout;
  final previous = await layout.adjacentPage(layout.firstPage, forward: atEnd);
  return previous?.layout;
}
