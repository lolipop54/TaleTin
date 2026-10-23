import 'dart:convert';

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/normalization/source_position_matcher.dart';

/// 文件修改后只接受唯一的原文与上下文匹配，不以旧章号、比例猜测。
class SourcePositionResolver {
  SourcePositionResolver(
    this.contents, {
    this.sourceSignature,
    this.loadMatches,
    this.saveMatches,
  });
  final ChapterContentRepository contents;
  final Future<String> Function(String, List<Chapter>)? sourceSignature;
  final Future<Map<String, Locator?>> Function(String, List<Chapter>)?
  loadMatches;
  final Future<void> Function(String, List<Chapter>, Map<String, Locator?>)?
  saveMatches;
  final _cache = <String, (String, Map<String, Locator?>)>{};

  Future<Locator?> resolve(Locator old, List<Chapter> chapters) async {
    if (!old.needsRelocation) return old;
    return (await resolveMany([old], chapters)).single;
  }

  /// 一次遍历为多个位置找唯一匹配，避免每条笔记都重新解析整本书。
  Future<List<Locator?>> resolveMany(
    List<Locator> old,
    List<Chapter> chapters,
  ) async {
    if (old.isEmpty) return [];
    final version = await sourceSignature?.call(old.first.bookId, chapters);
    final stored = version != null && _cache[old.first.bookId]?.$1 == version
        ? _cache[old.first.bookId]!.$2
        : await loadMatches?.call(old.first.bookId, chapters) ??
              <String, Locator?>{};
    final queries = <String, Locator>{};
    for (final point in old) {
      final key = jsonEncode(point.toJson());
      if (!point.needsRelocation) continue;
      if (stored.containsKey(key)) continue;
      final needle = point.exact.isNotEmpty ? point.exact : point.prefix;
      if (needle.isEmpty && point.imageResource == null) {
        stored[key] = null;
        continue;
      }
      queries.putIfAbsent(key, () => point);
    }
    if (queries.isNotEmpty) {
      final background = await contents.matchSourcePositions(
        old.first.bookId,
        chapters,
        queries.values.toList(),
      );
      if (background != null) {
        stored.addAll(background);
      } else {
        final matcher = SourcePositionMatcher(queries.values.toList());
        for (final chapter in chapters) {
          final content = await contents.chapter(
            old.first.bookId,
            chapter,
            textOnly: true,
          );
          matcher.add(chapter.id, content.blocks);
        }
        stored.addAll(matcher.finish());
      }
      await saveMatches?.call(old.first.bookId, chapters, stored);
    }
    if (version != null) {
      _cache.remove(old.first.bookId);
      _cache[old.first.bookId] = (version, stored);
      while (_cache.length > 2) {
        _cache.remove(_cache.keys.first);
      }
    }
    return [
      for (final point in old)
        point.needsRelocation ? stored[jsonEncode(point.toJson())] : point,
    ];
  }
}
