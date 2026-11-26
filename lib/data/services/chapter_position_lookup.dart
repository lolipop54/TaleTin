part of '../repositories/file_chapter_content_repository.dart';

// 独立入口只捕获路径与快照，正文仓库和在途任务留在各自的 isolate。
typedef _PositionWork = (String, String?, String, List<Chapter>, List<Locator>);
Future<Map<String, Locator?>> _matchInBackground(_PositionWork input) =>
    Isolate.run(() => _matchPositions(input));

Future<Map<String, Locator?>> _matchPositions(_PositionWork input) async {
  final (library, cache, bookId, chapters, anchors) = input;
  final contents = FileChapterContentRepository(
    libraryRoot: library,
    cacheRoot: cache,
  );
  try {
    final matcher = SourcePositionMatcher(anchors);
    for (final chapter in chapters) {
      final content = await contents.chapter(bookId, chapter, textOnly: true);
      matcher.add(chapter.id, content.blocks);
    }
    return matcher.finish();
  } finally {
    await contents.close();
  }
}
