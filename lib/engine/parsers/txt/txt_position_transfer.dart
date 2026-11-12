import 'dart:convert';

import '../../../domain/models/locator.dart';
import '../../../domain/models/source_position_preparation.dart';
import '../../normalization/text_normalizer.dart';
import 'txt_source_lines.dart';

/// 把旧章内段号换成原文件的行起点。重扫时同步找到这些行，不额外读取旧长章。
class TxtPositionTransfer {
  TxtPositionTransfer(TxtSourcePositionHints hints) {
    final byStart = <int, _OldChapter>{};
    for (final point in hints.positions) {
      final block = point.anchor.blockId;
      final paragraph = block.startsWith('b')
          ? int.tryParse(block.substring(1))
          : null;
      if (paragraph == null || paragraph < 1 || point.start >= point.end) {
        continue;
      }
      final chapter = byStart.putIfAbsent(
        point.start,
        () => _OldChapter(point.start, point.end),
      );
      (chapter.anchors[paragraph] ??= []).add(point.anchor);
    }
    _chapters = byStart.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  late final List<_OldChapter> _chapters;
  final _anchorsByByte = <int, List<Locator>>{};
  int _index = 0, _paragraph = 0;

  bool hasAnchorAt(int start) => _anchorsByByte.containsKey(start);

  void observe(TxtSourceLine line) {
    while (_index < _chapters.length && line.start >= _chapters[_index].end) {
      _index++;
      _paragraph = 0;
    }
    if (_index == _chapters.length || line.start < _chapters[_index].start) {
      return;
    }
    final text = line.normalizedText ?? normalizeParagraph(line.text);
    if (text.isEmpty) return;
    final anchors = _chapters[_index].anchors[++_paragraph];
    if (anchors != null) _anchorsByByte[line.start] = anchors;
  }

  void restore(
    int start,
    String text,
    String chapterId,
    String blockId,
    Map<String, Locator> matches,
  ) {
    final anchors = _anchorsByByte[start];
    if (anchors == null) return;
    for (final anchor in anchors) {
      final offset = anchor.utf16Offset;
      if (offset < anchor.prefix.length ||
          offset > text.length ||
          !text.startsWith(anchor.prefix, offset - anchor.prefix.length) ||
          !text.startsWith(anchor.exact, offset) ||
          !text.startsWith(anchor.suffix, offset)) {
        continue;
      }
      final query = jsonEncode(anchor.copyWith(needsRelocation: true).toJson());
      matches[query] = anchor.copyWith(chapterId: chapterId, blockId: blockId);
    }
  }
}

class _OldChapter {
  _OldChapter(this.start, this.end);
  final int start, end;
  final anchors = <int, List<Locator>>{};
}
