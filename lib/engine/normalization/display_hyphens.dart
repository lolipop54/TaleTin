import 'dart:convert';

import 'package:html/dom.dart';

/// 显示文本可新增软断点，但原文偏移始终只计书籍本来的字符。
class HyphenatedText {
  HyphenatedText(this.text, this.insertions);
  final String text;
  final List<int> insertions;

  int sourceOffset(int displayOffset) =>
      displayOffset - insertions.where((i) => i < displayOffset).length;

  int displayOffset(int sourceOffset) {
    var offset = sourceOffset;
    for (final point in insertions) {
      if (point > offset) break;
      offset++;
    }
    return offset;
  }

  String get source => removeInsertedHyphens(text, insertions);
}

String removeInsertedHyphens(String text, List<int> insertions) {
  if (insertions.isEmpty) return text;
  final points = insertions.toSet();
  return String.fromCharCodes([
    for (var i = 0; i < text.length; i++)
      if (!points.contains(i)) text.codeUnitAt(i),
  ]);
}

/// 属性只记录本应用新增的字符，不把书籍已有的软连字符当作新断点删除。
List<int> insertedHyphensOf(Text node) {
  final parent = node.parent;
  if (parent == null) return const [];
  // 源书通常没有显示层插入的断点。先检查标记，避免每个缩进/正文文本节点
  // 都在线性遍历同级节点；章节较长时，这种重复查找会接近平方级开销。
  if (!parent.attributes.keys.any(
    (key) => key is String && key.startsWith('data-gt-hyphens-'),
  )) {
    return const [];
  }
  final raw =
      parent.attributes['data-gt-hyphens-${parent.nodes.indexOf(node)}'];
  return raw == null ? const [] : (jsonDecode(raw) as List).cast<int>();
}
