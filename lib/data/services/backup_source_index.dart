import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../domain/models/backup_manifest.dart';
import '../../domain/models/source_content_index.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/mobi/mobi_source.dart';
import '../../engine/parsers/epub/epub_parser.dart';
import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/services/book_parser.dart';

import 'package:crypto/crypto.dart';

import '../database/app_database.dart';
import 'prepare_epub_toc_metadata.dart';

/// 新书备份保存原书和来源索引，不要求携带可重建的章节 JSON。
/// 源文件摘要、数据库章节和来源索引必须对应，才能保持位置正确。
Future<Set<String>> validateBackupSourceIndexes(
  Directory root,
  BackupManifest manifest,
  AppDatabase db, {
  bool verifySourceRecipes = true,
}) async {
  final indexed = <String>{};
  final files = {for (final file in manifest.files) file.path: file};
  for (final book in await db.select(db.books).get()) {
    if (book.status != 'active') continue;
    final prefix = 'library/${book.id}/content/${book.contentVersion}';
    final file = File('${root.path}/$prefix/manifest.json');
    if (!await file.exists()) continue;
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (raw['sourceIndex'] == null) continue;
    final index = SourceContentIndex.fromJson(
      raw['sourceIndex'] as Map<String, dynamic>,
    );
    final source = files['library/${book.id}/source.${book.format}'];
    if (raw['contentVersion'] != book.contentVersion ||
        index.format != book.format ||
        source == null ||
        source.sha256 != index.sourceDigest ||
        source.size != index.sourceBytes) {
      throw const FormatException('源书与正文索引不一致');
    }
    final chapters = await (db.select(
      db.chapters,
    )..where((c) => c.bookId.equals(book.id))).get();
    final mobi = index.format == 'mobi' || index.format == 'azw3';
    if (verifySourceRecipes &&
        index.format == 'epub' &&
        (index.tocPositions.isNotEmpty || index.tocHeadings.isNotEmpty)) {
      await validateEpubTocMetadata('${root.path}/${source.path}', raw);
    }
    Set<String>? directEntries;
    if (index.directMobi) {
      if (manifest.storageVersion < 2 ||
          files['$prefix/mobi.index']?.sha256 != index.mobiIndex['sha256'] ||
          files['$prefix/mobi.index']?.size != index.mobiIndex['bytes']) {
        throw const FormatException('MOBI读取索引缺失、损坏或备份版本不符');
      }
      final sourcePath = '${root.path}/${source.path}';
      final indexPath = '${root.path}/$prefix/mobi.index';
      directEntries = await Isolate.run(
        () => _validateDirectMobi(
          sourcePath,
          indexPath,
          index.mobiIndex['sha256'] as String,
          index.mobiIndex['bytes'] as int,
          verifySourceRecipes,
          raw,
        ),
      );
    } else if (mobi) {
      if (index.publication.isEmpty ||
          !index.publication.containsKey('content.opf')) {
        throw const FormatException('MOBI／AZW3 缺少重建内容清单');
      }
      for (final entry in index.publication.entries) {
        final path = '$prefix/publication/${entry.key}';
        if (!BackupEntry.isSafePath(path) ||
            files[path]?.sha256 != entry.value) {
          throw const FormatException('MOBI／AZW3 重建内容缺失或损坏');
        }
      }
    }
    final metadata = {
      for (final c in raw['chapters'] as List) (c as Map)['id'] as String: c,
    };
    if (index.chapters.length != chapters.length ||
        metadata.length != chapters.length) {
      throw const FormatException('正文来源索引缺少章节');
    }
    for (final chapter in chapters) {
      final location = index.chapters[chapter.id];
      final meta = metadata[chapter.id];
      if (location == null ||
          meta == null ||
          meta['ordinal'] != chapter.ordinal ||
          meta['textLength'] != chapter.textLength ||
          meta['path'] != chapter.contentPath ||
          meta['href'] != chapter.href) {
        throw const FormatException('章节索引与数据库不一致');
      }
      if (book.format == 'txt') {
        if (location.length != 2 ||
            location[0] is! int ||
            location[1] is! int ||
            (location[0] as int) < 0 ||
            (location[1] as int) <= (location[0] as int) ||
            (location[1] as int) > index.sourceBytes) {
          throw const FormatException('TXT 章节字节范围无效');
        }
      } else if (book.format == 'pdf') {
        if (location.length != 1 ||
            location.single != chapter.ordinal ||
            !files.containsKey('$prefix/${chapter.id}.json')) {
          throw const FormatException('PDF页面正文或来源页码缺失');
        }
        final content = ChapterContent.fromJson(
          (jsonDecode(
            await File('${root.path}/$prefix/${chapter.id}.json')
                .readAsString(),
          ) as Map).cast<String, Object?>(),
        );
        if (content.pdfPage?.index != chapter.ordinal ||
            content.textLength != chapter.textLength ||
            content.blocks.isEmpty ||
            content.pdfPage!.blocks.length != content.blocks.length) {
          throw const FormatException('PDF正文与原页对应关系不一致');
        }
      } else if (location.length != 1 ||
          location.single is! String ||
          !BackupEntry.isSafePath('library/${location.single}')) {
        throw const FormatException('EPUB 章节路径无效');
      }
      if (mobi &&
          !(index.directMobi
              ? directEntries!.contains(location.single)
              : index.publication.containsKey(location.single))) {
        throw const FormatException('MOBI／AZW3 重建章节缺失');
      }
    }
    final deferredImages = <String>[];
    for (final image in index.images.entries) {
      final path = image.key;
      if (!BackupEntry.isSafePath('$prefix/res/$path')) {
        throw const FormatException('正文图片资源路径越界');
      }
      if (files.containsKey('$prefix/res/$path')) continue;
      if (index.format == 'pdf' &&
          image.value.length == 2 &&
          image.value[0] == -1 &&
          image.value[1] == -1 &&
          RegExp(r'^pdf/p\d+-b\d+\.png$').hasMatch(path)) {
        continue;
      }
      if (index.directMobi && directEntries!.contains(path)) continue;
      if (mobi &&
          index.publication.containsKey(path) &&
          image.value.length == 2 &&
          image.value[0] == -1 &&
          image.value[1] == -1) {
        continue;
      }
      // [-1, -1] 是按需提取的图片；原书已经随快照保存，不要求未读图片落盘。
      // 旧索引里的已知尺寸不会触发重新提取，仍须保留对应的资源文件。
      if (index.format != 'epub' ||
          image.value.length != 2 ||
          image.value[0] != -1 ||
          image.value[1] != -1) {
        throw const FormatException('正文图片资源缺失');
      }
      deferredImages.add(path);
    }
    if (deferredImages.isNotEmpty) {
      final sourcePath = '${root.path}/${source.path}';
      // 只检查备份中的 ZIP 条目，不解压整本图片，也不读取旧手机的外部路径。
      await Isolate.run(
        () => _validateDeferredImages(sourcePath, deferredImages),
      );
    }
    indexed.add(book.id);
  }
  return indexed;
}

Future<Set<String>> _validateDirectMobi(
  String source,
  String path,
  String digest,
  int bytes,
  bool rebuild,
  Map<String, dynamic> manifest,
) async {
  final stored = MobiPublicationSource.open(
    source,
    File(path),
    digest: digest,
    bytes: bytes,
  );
  try {
    if (rebuild) {
      final fresh = await MobiPublicationSource.build(
        source,
        isCancelled: () => false,
      );
      try {
        if (sha256.convert(fresh.exportIndex()).toString() != digest) {
          throw const FormatException('MOBI读取索引与原书内容不一致');
        }
        final temporary = await Directory.systemTemp.createTemp(
          'mobi-restore-proof-',
        );
        try {
          final document = await const EpubParser().parse(
            ParseRequest(
              format: BookFormat.fromCode(
                (manifest['sourceIndex'] as Map)['format'] as String,
              )!,
              sourcePath: source,
              displayName: 'source.mobi',
              workDir: temporary.path,
              contentVersion: kContentVersion,
              indexedContent: true,
            ),
            entryArchive: EpubArchive.entries(fresh),
            onProgress: (_) {},
            isCancelled: () => false,
          );
          final expected = document.toManifestJson();
          final positions = (manifest['sourceIndex'] as Map)['tocPositions1'];
          if (positions != null &&
              jsonEncode(positions) !=
                  jsonEncode(document.sourceIndex!.tocPositions)) {
            throw const FormatException('MOBI目录位置与原书不一致');
          }
          final headings = (manifest['sourceIndex'] as Map)['tocHeadings1'];
          if (headings != null &&
              jsonEncode(headings) !=
                  jsonEncode(document.sourceIndex!.tocHeadings)) {
            throw const FormatException('MOBI目录标题位置与原书不一致');
          }
          if (jsonEncode(manifest['chapters']) !=
                  jsonEncode(expected['chapters']) ||
              jsonEncode(manifest['toc']) != jsonEncode(expected['toc'])) {
            throw const FormatException('MOBI目录或章节统计与原书不一致');
          }
        } finally {
          await temporary.delete(recursive: true);
        }
      } finally {
        fresh.close();
      }
    }
    return stored.sizes.keys.toSet();
  } finally {
    stored.close();
  }
}

void _validateDeferredImages(String sourcePath, List<String> paths) {
  final archive = EpubArchive.open(sourcePath);
  try {
    for (final path in paths) {
      if (!archive.contains(path)) {
        throw const FormatException('正文图片资源缺失');
      }
    }
  } finally {
    archive.close();
  }
}
