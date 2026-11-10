import 'english_hyphenation.dart';

/// 正文显示用的软断点。保留原文，借用现有偏移映射供断行结果换回UTF-16坐标。
abstract final class ProseLineBreaks {
  // 编号、电话、日期等数字串可在已有连字符后换行；不改小数、正负号，
  // 也不拆作者明确使用的不换行连字符U+2011。
  static final _numericHyphen = RegExp(r'[0-9][-\u2010](?=[0-9])');
  // 公式／编号后的长点线可在点之间续行。否则 TextPainter 可能把整串点
  // 当作一个词，优先在前面的斜杠后断开，把本来能放下的 2y/9 拆成两行。
  static final _leaders = RegExp(r'([·‧⋅.．])\1{3,}');
  // 默认非中文断行会把“（Graf），“Graf””连成过长的一组，宁可在
  // “伯爵”后提前换行。中文闭标点后允许开始新的括号／引号／英文词，
  // 但不能把逗号、右括号等闭标点孤立到下一行。
  static final _cjkPunctuation = RegExp(
    r'[）】》」』”’。，、；：！？](?=[（【《「『“‘A-Za-z0-9])',
  );

  static HyphenatedText display(String source, {bool hyphenate = true}) {
    final base = hyphenate
        ? EnglishHyphenation.display(source)
        : HyphenatedText(source, const []);
    final breaks = _numericHyphen
        .allMatches(base.text)
        .map((m) => m.end)
        .toSet();
    breaks.addAll(_cjkPunctuation.allMatches(base.text).map((m) => m.end));
    for (final match in _leaders.allMatches(base.text)) {
      for (var at = match.start + 1; at < match.end; at++) {
        breaks.add(at);
      }
    }
    if (breaks.isEmpty) return base;
    final old = base.insertions.toSet();
    final buffer = StringBuffer();
    final insertions = <int>[];
    for (var i = 0; i < base.text.length; i++) {
      if (breaks.contains(i)) {
        insertions.add(buffer.length);
        buffer.write('\u200b');
      }
      // 英文软连字符与新增零宽断点都只属于显示层，统一扣除后才是原文偏移。
      if (old.contains(i)) insertions.add(buffer.length);
      buffer.writeCharCode(base.text.codeUnitAt(i));
    }
    return HyphenatedText(buffer.toString(), insertions);
  }
}
