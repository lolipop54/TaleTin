part of 'reader_session_view_model.dart';

/// 阅读页提前准备并保留标题索引，面板打开和拖动期间只查内存。
///
/// 目录条目与位置的换算（[TocProgressEntry]、[tocEntryIndexAt]）已移到
/// `domain/services/toc_entry_index.dart`，听书那边复用同一套纯计算。
final progressTitlesProvider = FutureProvider.autoDispose
    .family<List<TocProgressEntry>, String>(
      (ref, bookId) => traceTurnStep(
        'load toc-index',
        () => _loadProgressTitles(ref, bookId),
      ),
    );

/// 正文和原书网页可先准备本页的精确章名，揭开首屏前再等全书索引。
final pageProgressTitlesProvider = FutureProvider.autoDispose
    .family<List<TocProgressEntry>, (String, int)>((ref, key) {
      final (bookId, ordinal) = key;
      final all = ref.watch(
        progressTitlesProvider(bookId).select((s) => s.value),
      );
      return all ?? _loadProgressTitles(ref, bookId, ordinal: ordinal);
    });

Future<List<TocProgressEntry>> _loadProgressTitles(
  Ref ref,
  String bookId, {
  int? ordinal,
}) async {
  final chapters = ref.watch(
    readerSessionProvider(bookId).select((s) => s.value?.chapters),
  );
  if (chapters == null) return [];
  final repository = ref.read(chapterContentRepositoryProvider);
  final session = ref.read(readerSessionProvider(bookId)).value!;
  final toc = await ref.watch(bookTocProvider(bookId).future);
  if (!ref.mounted) return [];
  final (names, signature) = await prepareTocIndex(session.book, chapters, toc);
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
  if (!ref.mounted) return [];
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

  // 未单列目录的内部续段沿用前一条；书前没有前项时沿用首条。
  final indices = ordinal == null
      ? Iterable<int>.generate(chapters.length)
      : _pageTitleChapters(chapters, names, toc.isEmpty, ordinal);
  final needsAnchors =
      session.book.format.usesOriginalWebView &&
      indices
          .map((i) => chapters[i])
          .any(
            (c) =>
                c.href != null &&
                (names[c.id]?.any((t) => t.anchorId?.isNotEmpty == true) ??
                    false) &&
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
    for (final i in indices) {
      final chapter = chapters[i], titles = names[chapters[i].id];
      // 有正式目录时，内部读取续段不能成为“下一章”的独立目标。
      if (titles == null && toc.isNotEmpty) continue;
      if (titles == null ||
          titles.length == 1 && (titles.single.anchorId?.isEmpty ?? true)) {
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
      final html = positions != null || source == null || chapter.href == null
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
    if (ordinal == null) {
      await repository.writeTocProgress(bookId, signature, result);
    }
    return result;
  } finally {
    await source?.close();
  }
}

Iterable<int> _pageTitleChapters(
  List<Chapter> chapters,
  Map<String, List<TocTitleRef>> names,
  bool noToc,
  int ordinal,
) {
  if (ordinal >= chapters.length) return const [];
  if (noToc || names.containsKey(chapters[ordinal].id)) return [ordinal];
  for (var i = ordinal - 1; i >= 0; i--) {
    if (names.containsKey(chapters[i].id)) return [i];
  }
  for (var i = ordinal + 1; i < chapters.length; i++) {
    if (names.containsKey(chapters[i].id)) return [i];
  }
  return const [];
}
