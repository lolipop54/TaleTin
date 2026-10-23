import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';

/// 全书库共用的可重建缓存，仅后台正文任务访问；不加入书库备份。
class ChapterDiskCache {
  ChapterDiskCache(this.root);
  final String? root;

  String _path(String key) => p.join(root!, key);

  ChapterContent? read(String key, Chapter chapter) {
    if (root == null) return null;
    final file = File(_path(key));
    if (!file.existsSync()) return null;
    try {
      final content = ChapterContent.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
      if (content.chapterId != chapter.id ||
          content.textLength != chapter.textLength) {
        throw const FormatException('章节缓存不完整');
      }
      return content;
    } on FormatException {
      _remove(file.path);
    } on TypeError {
      _remove(file.path);
    } on FileSystemException {
      // 可重建缓存被系统清掉或暂时不可读，改从原书准备，不影响正确正文。
    }
    return null;
  }

  void write(String key, ChapterContent content) {
    if (root == null) return;
    final bytes = content.encode();
    final file = File(_path(key));
    // 不按容量淘汰，不扫描其他书或改写命中章的访问时间。只替换本章缓存。
    file.parent.createSync(recursive: true);
    final next = File('${file.path}.next');
    next.writeAsBytesSync(bytes, flush: false);
    next.renameSync(file.path);
  }

  void _remove(String path) {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  void clear([String? bookId]) {
    if (root == null) return;
    final directory = Directory(bookId == null ? root! : p.join(root!, bookId));
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
