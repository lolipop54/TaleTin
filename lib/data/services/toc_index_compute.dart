import 'dart:convert';

import '../../core/concurrency/background_compute.dart';
import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/services/toc_entry_index.dart';
import '../../domain/services/toc_presentation.dart';

typedef TocIndexPreparation = (Map<String, List<TocTitleRef>>, String);
Future<TocIndexPreparation> prepareTocIndex(
  Book book,
  List<Chapter> chapters,
  List<TocNode> toc,
) => backgroundCompute(_prepare, (
  book,
  chapters,
  toc,
), enabled: largeToc(toc, chapters.length, backgroundListThreshold));
TocIndexPreparation _prepare((Book, List<Chapter>, List<TocNode>) input) {
  final (book, chapters, toc) = input;
  final names = collectTocTitles(toc);
  final signature = jsonEncode([
    2,
    book.contentVersion,
    book.textLength,
    book.format.name,
    [
      for (final chapter in chapters)
        [
          chapter.id,
          chapter.ordinal,
          chapter.title,
          chapter.textLength,
          chapter.href,
          [
            for (final title in names[chapter.id] ?? <TocTitleRef>[])
              [title.title, title.anchorId],
          ],
        ],
    ],
  ]);

  return (names, signature);
}
