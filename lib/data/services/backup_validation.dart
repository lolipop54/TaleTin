import 'dart:io';
import 'dart:typed_data';
import '../../domain/models/backup_manifest.dart';
import '../database/app_database.dart';

/// 在暂存库上迁移与检查；正式库在用户确认前始终不打开也不替换。
Future<int> validateBackupDatabase(Directory root, BackupManifest manifest) async {
  final file = File('${root.path}/database/reader.sqlite');
  final handle = await file.open();
  try {
    final header = await handle.read(100);
    if (header.length != 100 || String.fromCharCodes(header.take(16)) != 'SQLite format 3\u0000' ||
        ByteData.sublistView(header).getUint32(60, Endian.big) != manifest.databaseVersion) {
      throw const FormatException('数据库版本与备份清单不一致');
    }
  } finally { await handle.close(); }
  final db = AppDatabase.openFile(file);
  try {
    if ((await db.customSelect('PRAGMA integrity_check').getSingle()).data.values.single != 'ok' ||
        (await db.customSelect('PRAGMA foreign_key_check').get()).isNotEmpty) {
      throw const FormatException('数据库完整性检查失败');
    }
    if ((await db.select(db.importJobs).get()).isNotEmpty) throw const FormatException('备份包含未完成的导入任务');
    final paths = manifest.files.map((e) => e.path).toSet();
    var count = 0;
    for (final book in await db.select(db.books).get()) {
      if (book.id.contains('/') || !BackupEntry.isSafePath('library/${book.id}/source')) throw const FormatException('书籍编号包含非法路径');
      if (book.coverPath != null && !BackupEntry.isSafePath(
          'library/${book.id}/${book.coverPath}'.replaceAll('\\', '/'))) {
        throw const FormatException('封面路径越界');
      }
      if (book.status != 'removed') count++;
      if (book.status == 'active' && (!paths.contains('library/${book.id}/source.${book.format}') ||
          !paths.contains('library/${book.id}/content/${book.contentVersion}/manifest.json'))) {
        throw FormatException('备份缺少《${book.title}》的源书或正文清单');
      }
    }
    if (count != manifest.bookCount) throw const FormatException('书籍数量与备份清单不一致');
    for (final chapter in await db.customSelect('SELECT c.book_id, c.content_path, b.status FROM chapters c JOIN books b ON b.id=c.book_id').get()) {
      final path = 'library/${chapter.read<String>('book_id')}/${chapter.read<String>('content_path')}'.replaceAll('\\', '/');
      if (!BackupEntry.isSafePath(path) || (chapter.read<String>('status') == 'active' && !paths.contains(path))) {
        throw const FormatException('章节文件缺失或路径越界');
      }
    }
    return (await db.customSelect("SELECT COUNT(*) AS n FROM annotations WHERE kind <> 'bookmark'").getSingle()).read<int>('n');
  } finally { await db.close(); }
}
