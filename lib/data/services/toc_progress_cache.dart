import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/services/toc_entry_index.dart';

/// 只缓存目录的文字位置，不缓存正文或 DOM；正文版本、章序和目录共同校验。
class TocProgressCache {
  TocProgressCache(this.directory);
  final String directory;

  File _file(String bookId) =>
      File(p.join(directory, 'toc-progress', '$bookId.json'));

  Future<List<TocProgressEntry>?> read(String bookId, String signature) async {
    try {
      final file = _file(bookId);
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString()) as Map;
      if (value['signature'] != signature) return null;
      return [
        for (final row in value['entries'] as List)
          (
            progress: (row[0] as num).toDouble(),
            title: row[1] as String,
            chapterId: row[2] as String,
            anchorId: row[3] as String?,
          ),
      ];
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> write(
    String bookId,
    String signature,
    List<TocProgressEntry> entries,
  ) async {
    try {
      final file = _file(bookId);
      await file.parent.create(recursive: true);
      // 中断产生的残缺缓存会在下次读取时重建，不影响书籍、位置或目录原件。
      await file.writeAsString(
        jsonEncode({
          'signature': signature,
          'entries': [
            for (final e in entries)
              [e.progress, e.title, e.chapterId, e.anchorId],
          ],
        }),
      );
    } on FileSystemException {
      /* 缓存空间不足仍正常阅读。 */
    }
  }
}
