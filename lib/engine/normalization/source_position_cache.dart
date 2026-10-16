import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/locator.dart';

/// 同时缓存找到、重复及缺失的结果。完整清单摘要包含章节索引和解析规则，
/// 新目录发布后旧结果自然失效；不会把同路径换过内容的结果拿来复用。
abstract final class SourcePositionCache {
  static String signature(String directory) => sha256
      .convert(File(p.join(directory, 'manifest.json')).readAsBytesSync())
      .toString();

  static Map<String, Locator?> read(String directory) {
    final file = File(p.join(directory, 'position-matches.json'));
    if (!file.existsSync()) return {};
    final data = jsonDecode(file.readAsStringSync()) as Map;
    if (data['manifestDigest'] != signature(directory)) return {};
    return {
      for (final e in (data['matches'] as Map).entries)
        e.key as String: e.value == null ? null : Locator.fromJson(e.value),
    };
  }

  static void write(String directory, Map<String, Locator?> matches) {
    if (matches.isEmpty) return;
    final file = File(p.join(directory, 'position-matches.json'));
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode({
        'manifestDigest': signature(directory),
        'matches': {for (final e in matches.entries) e.key: e.value?.toJson()},
      }),
      flush: true,
    );
    temporary.renameSync(file.path);
  }
}
