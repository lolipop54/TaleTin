import 'dart:io';

import 'package:path/path.dart' as p;

/// 升级后仅删除旧版全文搜索索引目录；书库、数据库和其他缓存不在此目录。
Future<void> removeLegacySearchCache(String cacheRoot) async {
  final directory = Directory(p.join(cacheRoot, 'search'));
  if (await directory.exists()) await directory.delete(recursive: true);
}
