import 'dart:isolate';

import '../../../domain/models/book_document.dart';
import '../../../domain/models/speech_unit.dart';
import '../../../domain/services/logical_chapter_index.dart';
import '../../../engine/normalization/speech_unit_builder.dart';
import '../epub_source_repository.dart';
import 'listening_chapter_targets.dart';
import 'listening_titles.dart';

// 顶层函数隔开闭包上下文，避免把仓库连接、Future 缓存传进 isolate。
Future<List<ListeningTarget>> loadListeningTargets({
  required String bookId,
  required int version,
  required List<Chapter> files,
  required Chapter file,
  required ChapterContent content,
  required List<LogicalChapter> entries,
  required EpubSourceRepository? originals,
}) => _loadTargetsInWorker(
  bookId: bookId,
  version: version,
  files: files,
  file: file,
  content: content,
  entries: entries,
  libraryRoot: originals?.libraryRoot,
  cacheRoot: originals?.cacheRoot,
);

// 独立调用作用域：闭包只能捕获可传递的数据，不能捕获持有文件句柄的仓库。
Future<List<ListeningTarget>> _loadTargetsInWorker({
  required String bookId,
  required int version,
  required List<Chapter> files,
  required Chapter file,
  required ChapterContent content,
  required List<LogicalChapter> entries,
  required String? libraryRoot,
  required String? cacheRoot,
}) => Isolate.run(() async {
  String? html;
  if (entries.any(
    (e) => e.fragment != null && !e.fragment!.startsWith('gt-txt:'),
  )) {
    if (libraryRoot == null || cacheRoot == null) {
      throw StateError('没有原书锚点读取入口');
    }
    // 工作线程不读取 Flutter asset；目录只解析源节点，使用独立的可重建缓存。
    final source = EpubSourceRepository(
      libraryRoot: libraryRoot,
      cacheRoot: cacheRoot,
      hyphenateText: false,
    );
    final session = await source.open(
      bookId: bookId,
      contentVersion: version,
      chapters: files,
    );
    try {
      html = await session.chapterDocument(
        files.indexWhere((c) => c.id == file.id),
      );
    } finally {
      await session.close();
    }
  }
  return resolveListeningTargets(
    bookId: bookId,
    version: version,
    file: file,
    content: content,
    entries: entries,
    html: html,
  );
});

Future<List<SpeechUnit>> buildListeningUnits({
  required String bookId,
  required int version,
  required ChapterContent content,
  required List<ListeningTarget> targets,
  required String initialChapterId,
  required int maxLength,
}) => Isolate.run(() {
  final index = buildSpeechUnits(
    bookId: bookId,
    contentVersion: version,
    logicalChapterId: initialChapterId,
    content: content,
    maxUnitLength: maxLength,
  );
  final units = assignLogicalChapters(
    index.units,
    content,
    targets,
    initialChapterId,
  );
  return addListeningTitles(units, content, targets, maxLength);
});
