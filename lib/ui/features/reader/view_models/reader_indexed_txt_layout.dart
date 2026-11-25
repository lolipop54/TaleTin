part of 'reader_session_view_model.dart';

/// 长 TXT 只从索引读目标小节，普通短章走整章入口。
Future<ChapterLayout?> _layoutIndexedTxt(
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
  if (session.book.format != BookFormat.txt ||
      session.scrolling ||
      chapter.textLength < kLongTxtChapterLength) {
    return null;
  }
  final source = await ref
      .read(chapterContentRepositoryProvider)
      .txtChapterSource(bookId, chapter);
  if (!ref.mounted || token?.isCancelled == true) {
    throw const LayoutCancelled();
  }
  if (source == null) return null;
  return ref
      .read(readerEngineProvider)
      .layoutWindow(
        LayoutRequest.txtSections(
          book: session.book,
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapter: chapter,
          source: source,
          options: options,
          targetFirst: targetFirst,
          chapterOffset: target == null ? chapterOffset : null,
        ),
        target: target,
        atEnd: atEnd,
        token: token,
      );
}
