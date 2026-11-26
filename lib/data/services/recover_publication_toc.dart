import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';
import '../../domain/models/source_content_index.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_package.dart';
import '../../engine/parsers/epub/epub_parser.dart';
import '../../engine/parsers/mobi/mobi_html_toc.dart';
import '../../engine/parsers/mobi/mobi_toc_title_repair.dart';
import 'indexed_chapter_reader.dart';
import 'indexed_publication.dart';

/// 只从已核验的同一原书恢复目录，不重导入、改章节ID或写阅读位置。
Future<List<TocNode>> recoverPublicationToc({
  required String sourcePath,
  required String bookDirectory,
  required String contentDirectory,
  required List<Chapter> chapters,
  required List<TocNode> existing,
  required int previousRevision,
  SourceContentIndex? index,
}) => Isolate.run(() async {
  final kindle = isKindleTocFormat(
    index?.format ??
        p.extension(sourcePath).toLowerCase().replaceFirst('.', ''),
  );
  if (!kindle && previousRevision >= 5) return existing;
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
    archive = EpubArchive.directory(
      '$contentDirectory/publication',
      mobiSource: kindle ? sourcePath : null,
    );
  } else {
    archive = EpubArchive.open(sourcePath);
  }
  try {
    final nodes = kindle && existing.isNotEmpty
        ? existing
        : EpubParser.resolveTocInArchive(archive, chapters);
    if (!kindle) return nodes;
    final titles = previousRevision < kKindleTocTitleRevision
        ? MobiTocTitleRepair.read(
                sourcePath,
                archive,
              )?.apply(nodes, chapters) ??
              nodes
        : nodes;
    final package = EpubPackage.parse(
      archive,
      EpubPackage.readOpfPath(archive),
    );
    return restoreMobiTocVolumes(archive, package, titles, chapters);
  } finally {
    archive.close();
  }
});
