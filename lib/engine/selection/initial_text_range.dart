import 'dart:isolate';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:direct_read_rust/chinese_selection.dart';

final _wordCharacter = RegExp(
  r'^(?:\p{Script=Latin}\p{M}*|\p{Nd})$',
  unicode: true,
);
final _han = RegExp(r'^\p{Script=Han}', unicode: true);
const _contextRadius = 64;

/// 长按中文取词典命中的词，查不到时取按住的完整字形。
/// 英文和数字继续连词，所有范围均使用原文的 UTF-16 偏移。
Future<({int start, int end})?> initialTextRange(
  String text,
  int offset, {
  ({int start, int end})? within,
}) async {
  if (offset < 0 || offset >= text.length) return null;
  final range = CharacterRange.at(text, offset, offset + 1);
  if (range.current.trim().isEmpty) return null;
  final start = range.stringBeforeLength;
  final end = start + range.current.length;
  final lower = math.min(within?.start ?? 0, start);
  final upper = math.max(within?.end ?? text.length, end);
  if (_han.hasMatch(range.current)) {
    // 只把触点附近的文字交给后台，避免长段落或整章参与分词。
    final context = CharacterRange.at(
      text,
      math.max(lower, start - _contextRadius),
      math.min(upper, end + _contextRadius),
    );
    final base = context.stringBeforeLength;
    final word = await _findChineseWord(context.current, start - base);
    if (word != null && base + word.end >= end) {
      final aligned = CharacterRange.at(
        text,
        base + word.start,
        base + word.end,
      );
      final wordStart = aligned.stringBeforeLength;
      final wordEnd = wordStart + aligned.current.length;
      if (wordStart >= lower && wordEnd <= upper) {
        return (start: wordStart, end: wordEnd);
      }
    }
  }
  if (_wordCharacter.hasMatch(range.current)) {
    range.expandBackWhile(_wordCharacter.hasMatch);
    range.expandWhile(_wordCharacter.hasMatch);
    final wordStart = range.stringBeforeLength;
    return (
      start: math.max(wordStart, lower),
      end: math.min(wordStart + range.current.length, upper),
    );
  }
  return (start: start, end: end);
}

// 独立函数使 isolate 只接收小段正文和触点偏移，不捕获整段文字或排版对象。
Future<({int start, int end})?> _findChineseWord(String context, int offset) =>
    Isolate.run(() => chineseWordAt(context, offset));
