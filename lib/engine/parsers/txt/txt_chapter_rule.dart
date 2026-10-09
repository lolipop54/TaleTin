/// TXT 章节标题识别规则（设计文档 6.3）。
///
/// 识别「卷 / 章 / 回 / 节 / Chapter」等独立标题行，不依赖目录数据。
/// 判定条件刻意保守：只有**独立成行、长度很短**的行才当作标题，
/// 避免正文里的「第一章」之类字样被误判。
library;

import '../../normalization/text_normalizer.dart';

enum TxtHeadingKind { volume, chapter }

/// 一个识别到的标题行。
class TxtHeading {
  const TxtHeading({
    required this.lineIndex,
    required this.title,
    required this.kind,
  });

  /// 标题在文本里的行号（0 起）
  final int lineIndex;
  final String title;
  final TxtHeadingKind kind;
}

class TxtChapterRule {
  const TxtChapterRule({this.customPattern});

  /// 用户自定义章节正则；null 表示用内置规则
  final String? customPattern;

  /// 标题行长度上限（含标点的中文标题通常远低于此值）
  static const int maxHeadingLength = 40;

  /// 自定义正则的长度上限：过长或嵌套量词的模式在长行上有回溯风险，
  /// 这里直接拒绝，配合「只测短行」共同限制执行时间。
  static const int maxPatternLength = 200;

  static final RegExp _volume = RegExp(
    r'^第\s*[0-9〇零一二三四五六七八九十百千万两]+\s*[卷部篇册]',
  );
  static final RegExp _chapter = RegExp(
    r'^第\s*[0-9〇零一二三四五六七八九十百千万两]+\s*[章节回]',
  );
  static final RegExp _english = RegExp(r'^(Chapter|CHAPTER)\s+[0-9IVXLC]+');

  /// 句号、分号仍作为正文线索；问号、叹号、省略号常见于独立章题。
  static final RegExp _sentencePunctuation = RegExp(r'[。；]');

  /// 判断一行是否为标题；不是则返回 null。
  ///
  /// 两道防误判门槛：
  /// 1. 有首行缩进的行一定是正文段落（中文小说标题顶格书写）；
  /// 2. 内置规则额外排除带句子标点的行，例如「第二章的内容如下。」
  ///    ——这行虽然以「第二章」开头，但明显是正文。
  TxtHeading? matchLine(String rawLine, int lineIndex) {
    if (isBlankLine(rawLine)) return null;
    if (hasIndent(rawLine)) return null;
    final title = normalizeInline(rawLine);
    if (title.isEmpty || title.length > maxHeadingLength) return null;

    final pattern = customPattern;
    if (pattern != null) {
      if (pattern.length > maxPatternLength) return null;
      final regExp = _compiled[pattern];
      if (regExp == null) return null;
      final match = regExp.firstMatch(title);
      // 必须从行首命中，避免正文中间的模式被当成标题
      if (match == null || match.start != 0) return null;
      return TxtHeading(
        lineIndex: lineIndex,
        title: title,
        kind: TxtHeadingKind.chapter,
      );
    }

    if (_sentencePunctuation.hasMatch(title)) return null;

    if (_volume.hasMatch(title)) {
      return TxtHeading(
        lineIndex: lineIndex,
        title: title,
        kind: TxtHeadingKind.volume,
      );
    }
    if (_chapter.hasMatch(title) || _english.hasMatch(title)) {
      return TxtHeading(
        lineIndex: lineIndex,
        title: title,
        kind: TxtHeadingKind.chapter,
      );
    }
    return null;
  }

  /// 是否以缩进开头（全角空格、半角空格、制表符）。
  static bool hasIndent(String line) {
    if (line.isEmpty) return false;
    final first = line.codeUnitAt(0);
    return first == 0x3000 || first == 0x20 || first == 0x09;
  }

  /// 自定义正则只在导入开始时编译一次，避免逐行重新编译。
  static final Map<String, RegExp?> _compiled = {};

  /// 预编译自定义正则；语法错误时返回 false，界面据此提示。
  static bool compileCustom(String pattern) {
    if (pattern.length > maxPatternLength) {
      _compiled[pattern] = null;
      return false;
    }
    try {
      _compiled[pattern] = RegExp(pattern);
      return true;
    } on FormatException {
      _compiled[pattern] = null;
      return false;
    }
  }
}
