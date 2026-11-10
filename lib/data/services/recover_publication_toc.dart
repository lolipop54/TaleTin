import 'dart:io';
import 'dart:isolate';

import '../../domain/models/book_document.dart';
import '../../domain/models/source_content_index.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_parser.dart';
import 'indexed_chapter_reader.dart';
import 'indexed_publication.dart';

/// 只从已核验的同一原书恢复目录，不重导入、改章节ID或写阅读位置。
Future<List<TocNode>> recoverPublicationToc({
  required String sourcePath,
  required String bookDirectory,
  required String contentDirectory,
  required List<Chapter> chapters,
  SourceContentIndex? index,
}) => Isolate.run(() async {
  EpubArchive archive;
  if (index != null) {
    final reader = IndexedChapterReader.open(
      bookDirectory,
      contentDirectory,
      preparedIndex: (kContentVersion, index),
    );
    try {
      await reader.verifySource();
      archive = openIndexedPublication(sourcePath, contentDirectory, index);
    } finally {
      await reader.close();
    }
  } else if (Directory('$contentDirectory/publication').existsSync()) {
    archive = EpubArchive.directory('$contentDirectory/publication');
  } else {
    archive = EpubArchive.open(sourcePath);
  }
  try {
    return EpubParser.resolveTocInArchive(archive, chapters);
  } finally {
    archive.close();
  }
});
