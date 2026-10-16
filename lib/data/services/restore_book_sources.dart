import 'dart:io';
import 'package:path/path.dart' as p;
import '../database/app_database.dart';

/// 备份中的原书已解压为独立文件，恢复后直接引用这一份，不再额外复制。
/// 在暂存库中绑定最终路径，发生回滚时不触碰恢复前书库。
Future<void> restoreBookSources(Directory staged, Directory destination) async {
  final database = AppDatabase.openFile(File(p.join(staged.path, 'database', 'reader.sqlite')));
  try {
    for (final book in await database.select(database.books).get()) {
      if ((book.status != 'active' && book.status != 'preparing') || !book.sourceHash.startsWith('file:')) continue;
      final relative = p.join('library', book.id, 'source.${book.format}');
      final path = p.join(destination.path, relative);
      await File(p.join(staged.path, 'library', book.id, 'source.path')).writeAsString(path, flush: true);
      await database.customStatement('UPDATE books SET source_hash = ? WHERE id = ?',
        [Uri.file(path).toString(), book.id]);
    }
  } finally { await database.close(); }
}
