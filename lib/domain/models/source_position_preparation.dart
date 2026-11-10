import 'dart:convert';

import 'book_document.dart';
import 'locator.dart';

/// 只在会改变章节、块编号、文字规范化或编码判断时递增；界面改动不影响它。
const sourcePositionRulesRevision = 1;

/// 记录自动章题检查是否已完成，和书的实际切章规则分别保存。
const txtHeadingRulesRevision = 2;
const txtSectionFallbackWarning = '未识别到章节标题，已按固定长度分成小节';

String sourcePositionRules(
  String format, {
  String? charset,
  String? chapterPattern,
  bool forceSections = false,
  bool usesIndentedTxtHeadings = false,
  bool usesCombinedTxtHeadings = false,
}) => jsonEncode([
  sourcePositionRulesRevision,
  kContentVersion,
  format,
  if (format == 'mobi' || format == 'azw3') 'libmobi90627420-publication1',
  if (format == 'pdf') 'pdf-text-and-page-map1',
  if (format == 'txt') ...[charset, chapterPattern, forceSections],
  if (usesIndentedTxtHeadings) 'indented-txt-headings1',
  if (usesCombinedTxtHeadings) 'combined-txt-headings1',
]);

/// 独立于可删除的正文缓存保存，重新导入只在摘要和规则均相同时复用旧坐标。
class SourcePositionProof {
  const SourcePositionProof(this.digest, this.rules, this.stamp);
  final String digest, rules, stamp;
  bool sameContent(SourcePositionProof other) =>
      digest == other.digest && rules == other.rules;
  Map<String, Object?> toJson() => {
    'digest': digest,
    'rules': rules,
    'stamp': stamp,
  };
  factory SourcePositionProof.fromJson(Map<String, dynamic> value) =>
      SourcePositionProof(
        value['digest'] as String,
        value['rules'] as String,
        value['stamp'] as String,
      );
}

class SourcePositionPreparation {
  const SourcePositionPreparation({this.proof, this.anchors = const []});
  final SourcePositionProof? proof;
  final List<Locator> anchors;
}

typedef LoadSourcePositions = Future<SourcePositionPreparation> Function(
  String bookId,
);
