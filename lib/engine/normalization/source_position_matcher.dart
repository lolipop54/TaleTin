import 'dart:convert';

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import 'locator_mapper.dart';

/// 导入扫描及旧索引恢复共用同一匹配器；只保留每个查询的一处候选和匹配数。
/// 少量摘录保留字符串查找；较多摘录共用前缀和转移，一遍扫描找到所有候选。
class SourcePositionMatcher {
  SourcePositionMatcher(List<Locator> anchors) {
    for (final anchor in anchors) {
      final key = jsonEncode(anchor.toJson());
      _queries.putIfAbsent(key, () => _Query(anchor));
    }
    _textQueries = _queries.values.where((q) => q.needle.isNotEmpty).toList();
    _imageQueries = _queries.values
        .where((q) => q.needle.isEmpty && q.old.imageResource != null)
        .toList();
    // Building a prefix table is unnecessary for the usual few saved endpoints.
    if (_textQueries.length > 16) _states = _buildStates(_textQueries);
  }
  final _queries = <String, _Query>{};
  late final List<_Query> _textQueries, _imageQueries;
  List<_MatchState>? _states;
  bool hasAmbiguous = false;
  bool get isEmpty => _queries.isEmpty;

  void add(String chapterId, List<ContentBlock> blocks) {
    for (final block in blocks) {
      final text = blockTextOf(block);
      if (block.kind == BlockKind.image) {
        for (final q in _imageQueries) {
          if (q.count < 2 && block.resourcePath == q.old.imageResource) {
            q.accept(chapterId, block, 0);
          }
        }
      }
      final states = _states;
      if (states != null) {
        var state = 0;
        for (var i = 0; i < text.length; i++) {
          final unit = text.codeUnitAt(i);
          while (state != 0 && !states[state].edges.containsKey(unit)) {
            state = states[state].fallback;
          }
          state = states[state].edges[unit] ?? 0;
          final matches = states[state].matches;
          for (var j = matches.length - 1; j >= 0; j--) {
            final q = matches[j];
            if (q.count < 2) {
              _accept(q, chapterId, block, text, i + 1 - q.needle.length);
            }
            // Ambiguity can never become uniqueness later in a full-book scan.
            // Remove that query from this state's hot list after the second hit.
            if (q.count > 1) matches.removeAt(j);
          }
        }
        continue;
      }
      for (final q in _textQueries) {
        if (q.count > 1) continue;
        var from = 0;
        while (from <= text.length) {
          final at = text.indexOf(q.needle, from);
          if (at < 0) break;
          from = at + 1;
          _accept(q, chapterId, block, text, at);
          if (q.count > 1) break;
        }
      }
    }
  }

  // Both search paths use exactly the same context and complete-character rule.
  void _accept(
    _Query q,
    String chapter,
    ContentBlock block,
    String text,
    int at,
  ) {
    final point = q.old;
    final offset = point.exact.isEmpty ? at + q.needle.length : at;
    if ((point.prefix.isNotEmpty &&
            (offset < point.prefix.length ||
                !text.startsWith(
                  point.prefix,
                  offset - point.prefix.length,
                ))) ||
        (point.suffix.isNotEmpty && !text.startsWith(point.suffix, offset)) ||
        snapToGrapheme(text, offset) != offset) {
      return;
    }
    q.accept(chapter, block, offset);
  }

  Map<String, Locator?> finish() {
    hasAmbiguous = _queries.values.any((q) => q.count > 1);
    return {
      for (final e in _queries.entries)
        e.key: e.value.count == 1 ? e.value.match : null,
    };
  }
}

class _MatchState {
  final edges = <int, int>{};
  final matches = <_Query>[];
  int fallback = 0;
}

List<_MatchState> _buildStates(List<_Query> queries) {
  final states = [_MatchState()];
  for (final q in queries) {
    var state = 0;
    for (final unit in q.needle.codeUnits) {
      var next = states[state].edges[unit];
      if (next == null) {
        next = states.length;
        states.add(_MatchState());
        states[state].edges[unit] = next;
      }
      state = next;
    }
    states[state].matches.add(q);
  }
  // Breadth first: inherited matches are ready before a child's fallback is used.
  final queue = [...states.first.edges.values];
  for (var cursor = 0; cursor < queue.length; cursor++) {
    final parent = queue[cursor];
    for (final edge in states[parent].edges.entries) {
      var fallback = states[parent].fallback;
      while (fallback != 0 && !states[fallback].edges.containsKey(edge.key)) {
        fallback = states[fallback].fallback;
      }
      fallback = states[fallback].edges[edge.key] ?? 0;
      states[edge.value].fallback = fallback;
      states[edge.value].matches.addAll(states[fallback].matches);
      queue.add(edge.value);
    }
  }
  return states;
}

class _Query {
  _Query(this.old) : needle = old.exact.isNotEmpty ? old.exact : old.prefix;
  final Locator old;
  final String needle;
  int count = 0;
  Locator? match;
  void accept(String chapter, ContentBlock block, int offset) {
    count++;
    match = count == 1
        ? LocatorMapper(
            bookId: old.bookId,
            contentVersion: kContentVersion,
            chapterId: chapter,
          ).at(block, offset, affinity: old.affinity)
        : null;
  }
}
