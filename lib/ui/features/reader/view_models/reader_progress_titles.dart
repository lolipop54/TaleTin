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
        final (names, signature) = await prepareTocIndex(
          session.book,
          chapters,
          toc,
        );
        if (!ref.mounted) return [];
        final cached = await repository.readTocProgress(bookId, signature);
        if (!ref.mounted) return [];
        if (cached != null) {
          traceTurn('load toc-index cache-hit');
          return cached;
        }
        // The manifest already came through the content repository. Complete
        // import metadata needs no second original-book worker or native index.
        final locations = await repository.tocLocations(
          bookId,
          session.book.contentVersion,
        );
        bool hasLocations(Chapter chapter) {
          final positions = locations?.anchors[chapter.id];
          if (positions == null) return false;
          return (names[chapter.id] ?? <TocTitleRef>[]).every(
            (title) =>
                title.anchorId == null ||
                title.anchorId!.isEmpty ||
                positions.containsKey(title.anchorId),
          );
        }

        final needsAnchors =
            session.book.format.usesOriginalWebView &&
            chapters.any(
              (c) =>
                  c.href != null &&
                  (names[c.id]?.length ?? 0) > 1 &&
                  !hasLocations(c),
            );
        final source = needsAnchors
            ? await ref
                  .read(epubSourceRepositoryProvider)
                  .open(
                    bookId: bookId,
                    contentVersion: session.book.contentVersion,
                    chapters: chapters,
                  )
            : null;
        final result = <TocProgressEntry>[];
        try {
          final prepared =
              locations?.anchors ??
              await source?.preparedTocPositions() ??
              const <String, Map<String, double?>>{};
          final headings =
              locations?.headings ??
              await source?.preparedTocHeadings() ??
              const <String, Map<String, double>>{};
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
            final positions =
                titles.every(
                  (title) => title.anchorId == null || title.anchorId!.isEmpty,
                )
                ? const <String, double?>{}
                : prepared[chapter.id] != null &&
                      titles.every(
                        (title) =>
                            title.anchorId == null ||
                            title.anchorId!.isEmpty ||
                            prepared[chapter.id]!.containsKey(title.anchorId),
                      )
                ? prepared[chapter.id]
                : source == null || chapter.href == null
                ? null
                : await source.chapterTocPositions(
                    i,
                    titles
                        .map((title) => title.anchorId)
                        .whereType<String>()
                        .toList(),
                  );
            final html =
                positions != null || source == null || chapter.href == null
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
              readContent: () => traceTurnStep(
                'load toc-content chapter=$i',
                () => repository.chapter(bookId, chapter, textOnly: true),
              ),
              titles: titles,
              isTxt: session.book.format == BookFormat.txt,
              html: html,
              preparedAnchorPositions: positions,
              preparedTitlePositions: headings[chapter.id],
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
          await source?.close();
        }
      }),
    );
