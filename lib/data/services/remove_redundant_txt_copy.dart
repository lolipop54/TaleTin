import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';

/// 只在启动、尚未接收导入/阅读/备份任务时调用。首次升级逐章校验一次，
/// 成功删除 text.txt 后，后续启动无需再扫描该书正文。
int removeRedundantTxtCopy(
  String bookDirectory,
  int version,
  List<Chapter> chapters,
) {
  final directory = p.join(bookDirectory, 'content', '$version');
  final copy = File(p.join(directory, 'text.txt'));
  if (!copy.existsSync() || chapters.isEmpty) return 0;
  try {
    final manifest = jsonDecode(
      File(p.join(directory, 'manifest.json')).readAsStringSync(),
    ) as Map;
    final recorded = manifest['chapters'] as List;
    if (manifest['contentVersion'] != version ||
        recorded.length != chapters.length) {
      return 0;
    }
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final row = recorded[i] as Map;
      if (row['id'] != chapter.id ||
          row['path'] != chapter.contentPath ||
          row['textLength'] != chapter.textLength) {
        return 0;
      }
      final data = jsonDecode(
        File(p.join(bookDirectory, chapter.contentPath)).readAsStringSync(),
      ) as Map;
      final content = ChapterContent.fromJson(data.cast<String, Object?>());
      if (content.chapterId != chapter.id ||
          content.textLength != chapter.textLength) {
        return 0;
      }
    }
    final bytes = copy.lengthSync();
    copy.deleteSync();
    return bytes;
  } on FileSystemException {
    return 0;
  } on FormatException {
    return 0;
  } on TypeError {
    return 0;
  }
}
