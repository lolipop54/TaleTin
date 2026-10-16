import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../domain/models/backup_manifest.dart';
import '../../domain/models/source_content_index.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../database/app_database.dart';

/// 新书备份保存原书和来源索引，不要求携带可重建的章节 JSON。
/// 源文件摘要、数据库章节和来源索引必须对应，才能保持位置正确。
Future<Set<String>> validateBackupSourceIndexes(
  Directory root,
  BackupManifest manifest,
  AppDatabase db,
) async {
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
      } else if (location.length != 1 ||
          location.single is! String ||
          !BackupEntry.isSafePath('library/${location.single}')) {
        throw const FormatException('EPUB 章节路径无效');
      }
    }
    final deferredImages = <String>[];
    for (final image in index.images.entries) {
      final path = image.key;
      if (!BackupEntry.isSafePath('$prefix/res/$path')) {
        throw const FormatException('正文图片资源路径越界');
      }
      if (files.containsKey('$prefix/res/$path')) continue;
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
