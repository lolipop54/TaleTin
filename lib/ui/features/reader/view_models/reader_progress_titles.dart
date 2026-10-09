part of 'reader_session_view_model.dart';

/// 阅读页提前准备并保留标题索引，面板打开和拖动期间只查内存。
///
/// 目录条目与位置的换算（[TocProgressEntry]、[tocEntryIndexAt]）已移到
/// `domain/services/toc_entry_index.dart`，听书那边复用同一套纯计算。
final progressTitlesProvider = FutureProvider.autoDispose
    .family<List<TocProgressEntry>, String>(
      (ref, bookId) => traceTurnStep('load toc-index', () async {
        final chapters = ref.watch(
          readerSessionProvider(bookId).select((s) => s.value?.chapters),
        );
        if (chapters == null) return [];
        final toc = await ref.watch(bookTocProvider(bookId).future);
        final repository = ref.read(chapterContentRepositoryProvider);
        final session = ref.read(readerSessionProvider(bookId)).value!;
        final names = collectTocTitles(toc);
        final signature = jsonEncode([
          2,
          session.book.contentVersion,
          session.book.textLength,
          session.book.format.name,
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
        final cached = await repository.readTocProgress(bookId, signature);
        if (!ref.mounted) return [];
        if (cached != null) {
          traceTurn('load toc-index cache-hit');
          return cached;
        }
        final needsAnchors =
            session.book.format == BookFormat.epub &&
            chapters.any(
              (c) => c.href != null && (names[c.id]?.length ?? 0) > 1,
            );
        final source = needsAnchors
            ? ref
                  .read(epubSourceRepositoryProvider)
                  .open(
                    bookId: bookId,
                    contentVersion: session.book.contentVersion,
                    chapters: chapters,
                  )
            : null;
        final result = <TocProgressEntry>[];
        try {
          for (var i = 0; i < chapters.length; i++) {
            final chapter = chapters[i], titles = names[chapters[i].id];
            if (titles == null || titles.length < 2) {
              result.add((
                progress: session.bookProgressAt(i, 0),
                title: titles?.single.title ?? chapter.title,
                chapterId: chapter.id,
                anchorId: titles?.single.anchorId,
              ));
              continue;
            }
            final content = await traceTurnStep(
              'load toc-content chapter=$i',
              () => repository.chapter(bookId, chapter, textOnly: true),
            );
            final html = source == null || chapter.href == null
                ? null
                : await traceTurnStep(
                    'load toc-html chapter=$i',
                    () => source.chapterDocument(i),
                  );
            if (!ref.mounted) return [];
            final chapterEntries = await prepareChapterTocEntries(
              bookId: bookId,
              version: session.book.contentVersion,
              chapter: chapter,
              content: content,
              titles: titles,
              isTxt: session.book.format == BookFormat.txt,
              html: html,
            );
            if (!ref.mounted) return [];
            for (final entry in chapterEntries) {
              result.add((
                progress: session.bookProgressAt(i, entry.progress),
                title: entry.title,
                chapterId: entry.chapterId,
                anchorId: entry.anchorId,
              ));
            }
          }
          await repository.writeTocProgress(bookId, signature, result);
          return result;
        } finally {
          source?.close();
        }
      }),
    );
