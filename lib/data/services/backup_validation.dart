import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models/backup_manifest.dart';
import '../database/app_database.dart';
import '../repositories/book_cover_repository.dart';
import '../repositories/reading_background_repository.dart';
import '../../domain/models/reading_background.dart';

import 'package:image/image.dart' as image;

import 'backup_source_index.dart';
import 'imported_font_store.dart';
import '../../domain/services/library_file_gate.dart';

/// 在暂存库上迁移与检查；正式库在用户确认前始终不打开也不替换。
Future<int> validateBackupDatabase(
  Directory root,
  BackupManifest manifest, {
  bool verifySourceRecipes = true,
}) async {
  final file = File('${root.path}/database/reader.sqlite');
  final handle = await file.open();
  try {
    final header = await handle.read(100);
    if (header.length != 100 ||
        String.fromCharCodes(header.take(16)) != 'SQLite format 3\u0000' ||
        ByteData.sublistView(header).getUint32(60, Endian.big) !=
            manifest.databaseVersion) {
      throw const FormatException('数据库版本与备份清单不一致');
    }
  } finally {
    await handle.close();
  }
  final db = AppDatabase.openFile(file);
  try {
    await ImportedFontStore(
      Directory('${root.path}/fonts/imported'),
      LibraryFileGate(),
    ).validate();
    if ((await db.customSelect('PRAGMA integrity_check').getSingle())
                .data
                .values
                .single !=
            'ok' ||
        (await db.customSelect('PRAGMA foreign_key_check').get()).isNotEmpty) {
      throw const FormatException('数据库完整性检查失败');
    }
    if ((await db.select(db.importJobs).get()).isNotEmpty) {
      throw const FormatException('备份包含未完成的导入任务');
    }
    final paths = manifest.files.map((e) => e.path).toSet();
    for (final choice in (await DriftBookCoverRepository.loadDefaults(
      db,
    )).values) {
      if (choice.imagePath case final path?) {
        if (!path.startsWith('global-covers/') ||
            !paths.contains('library/$path')) {
          throw const FormatException('备份缺少全局自定义封面图片');
        }
      }
    }
    final backgrounds = ReadingBackgroundRepository(
      db,
      '${root.path}/library',
      LibraryFileGate(),
    );
    final customBackgrounds = await backgrounds.customImages();
    final ids = {
      ...ReadingBackground.presets.map((e) => e.id),
      ...customBackgrounds.map((e) => e.id),
    };
    for (final background in customBackgrounds) {
      final path = 'library/${background.path}';
      if (!paths.contains(path)) throw const FormatException('备份缺少阅读背景图片');
      final bytes = await File('${root.path}/$path').readAsBytes();
      final info = image.PngDecoder().startDecode(bytes);
      if (info == null ||
          info.width > 2048 ||
          info.height > 2048 ||
          image.decodePng(bytes) == null) {
        throw const FormatException('备份中的阅读背景图片损坏或尺寸无效');
      }
    }
    final selections =
        await (db.select(db.preferences)..where(
              (t) => t.key.equals(ReadingBackgroundRepository.selectionKey),
            ))
            .get();
    for (final selection in selections) {
      if (!ids.contains((jsonDecode(selection.valueJson) as Map)['id'])) {
        throw const FormatException('备份中的阅读背景选择无效');
      }
    }
    var count = 0;
    final books = await db.select(db.books).get();
    final covers = await DriftBookCoverRepository.load(
      db,
      books.map((b) => b.id),
    );
    for (final book in books) {
      if (book.id.contains('/') ||
          !BackupEntry.isSafePath('library/${book.id}/source')) {
        throw const FormatException('书籍编号包含非法路径');
      }
      if (book.coverPath != null &&
          !BackupEntry.isSafePath(
            'library/${book.id}/${book.coverPath}'.replaceAll('\\', '/'),
          )) {
        throw const FormatException('封面路径越界');
      }
      if (book.status != 'removed') count++;
      final cover = covers[book.id];
      if (cover?.imagePath case final path?) {
        if (!paths.contains('library/${book.id}/$path')) {
          throw const FormatException('备份缺少自定义封面图片');
        }
      }
      if (book.status == 'preparing' &&
          !paths.contains('library/${book.id}/source.${book.format}')) {
        throw FormatException('备份缺少《${book.title}》的待准备源文件');
      }
      if (book.status == 'active' &&
          (!paths.contains('library/${book.id}/source.${book.format}') ||
              !paths.contains(
                'library/${book.id}/content/${book.contentVersion}/manifest.json',
              ))) {
        throw FormatException('备份缺少《${book.title}》的源书或正文清单');
      }
    }
    if (count != manifest.bookCount) {
      throw const FormatException('书籍数量与备份清单不一致');
    }
    // 先核对数据库路径，再使用这些路径读取来源索引。
    final indexedBooks = await validateBackupSourceIndexes(
      root,
      manifest,
      db,
      verifySourceRecipes: verifySourceRecipes,
    );
    for (final chapter
        in await db
            .customSelect(
              'SELECT c.book_id, c.content_path, b.status FROM chapters c JOIN books b ON b.id=c.book_id',
            )
            .get()) {
      final path =
          'library/${chapter.read<String>('book_id')}/${chapter.read<String>('content_path')}'
              .replaceAll('\\', '/');
      if (!BackupEntry.isSafePath(path) ||
          (chapter.read<String>('status') == 'active' &&
              !indexedBooks.contains(chapter.read<String>('book_id')) &&
              !paths.contains(path))) {
        throw const FormatException('章节文件缺失或路径越界');
      }
    }
    return (await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM annotations WHERE kind <> 'bookmark'",
            )
            .getSingle())
        .read<int>('n');
  } finally {
    await db.close();
  }
}
