import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/services/toc_entry_index.dart';
import '../../../../engine/normalization/text_anchor.dart';
import 'reader_session_view_model.dart';

/// 想法属于选文位置。双列右页或滚动缓冲区可显示另一章，同一正文文件也可有多个目录落点。
Future<String> readerNoteTitle(
  WidgetRef ref,
  String bookId,
  Locator start, {
  String fallback = '',
  ChapterContent? fullContent,
}) async {
  final session = ref.read(readerSessionProvider(bookId)).value;
  if (session == null || session.book.contentVersion != start.contentVersion) {
    return fallback;
  }
  final index = session.chapters.indexWhere(
    (chapter) => chapter.id == start.chapterId,
  );
  if (index < 0) return fallback;
  final chapter = session.chapters[index];
  final repository = ref.read(chapterContentRepositoryProvider);
  final titles = await ref.read(progressTitlesProvider(bookId).future);
  if (titles.isEmpty) return chapter.title;
  var position = session.bookProgressAt(index, 0);
  if (titles.where((entry) => entry.chapterId == chapter.id).length > 1) {
    final content =
        fullContent ??
        await repository.chapter(bookId, chapter, textOnly: true);
    position = session.bookProgressAt(
      index,
      fractionOfLocator(
        content: content,
        bookId: bookId,
        contentVersion: session.book.contentVersion,
        chapterId: chapter.id,
        locator: start,
      ),
    );
  }
  return titles[tocEntryIndexAt(
        titles,
        position: position,
        chapterId: chapter.id,
        allowAnchorTolerance: false,
      )]
      .title;
}
