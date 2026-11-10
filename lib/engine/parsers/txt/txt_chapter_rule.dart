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
    this.partTitle,
    this.volumeTitle,
  });

  /// 标题在文本里的行号（0 起）
  final int lineIndex;
  final String title;
  final TxtHeadingKind kind;

  /// 合写章题自带的篇名（可省略）和卷名。
  final String? partTitle;
  final String? volumeTitle;
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

  static const _number = r'第\s*[0-9〇零一二三四五六七八九十百千万两]+\s*';
  static final RegExp _volume = RegExp('^$_number[卷部篇册]');
  static final RegExp _chapter = RegExp('^$_number[章节回]');
  static final RegExp _english = RegExp(r'^(Chapter|CHAPTER)\s+[0-9IVXLC]+');
  static final RegExp _indentedChinese = RegExp(r'^[ \t\u3000]+第');
  static final RegExp _encodedMiddleDot = RegExp(
    r'(?:(?:&#0*38;|&amp;)#|&#)(?:0*183|x0*b7|0*12539);|&middot;',
    caseSensitive: false,
  );
  static final RegExp _combined = RegExp(
    r'^(?:(?<part>[^·・•]+[篇部])\s*[·・•]\s*)?'
    '(?<volume>$_number[卷部篇册])'
    r'\s*(?:[·・•]\s*(?<volumeName>[^·・•]+?)?\s*(?:[·・•]\s*)?)?'
    '(?<chapter>$_number[章节回].*)\$',
  );

  /// 句号、分号仍作为正文线索；问号、叹号、省略号常见于独立章题。
  static final RegExp _sentencePunctuation = RegExp(r'[。；]');

  /// 判断一行是否为标题；不是则返回 null。
  ///
  /// 缩进章题需要空行和独立编号共同确认，以免把正文段落当成标题。
  TxtHeading? matchLine(
    String rawLine,
    int lineIndex, {
    bool afterBlankLine = false,
  }) {
    if (rawLine.isEmpty) return null;
    final pattern = customPattern;
    if (pattern == null && afterBlankLine) {
      final combined = _matchCombined(rawLine, lineIndex);
      if (combined != null) return combined;
    }
    final indented = hasIndent(rawLine);
    if (indented) {
      if (pattern != null ||
          !afterBlankLine ||
          !_indentedChinese.hasMatch(rawLine)) {
        return null;
      }
    } else if (pattern == null) {
      // 内置顶格标题只检查可能以“第”或 C 开头的行，保留原先允许的前导空白。
      final possible = switch (rawLine.codeUnitAt(0)) {
        0x7b2c || 0x43 || 0x0a || 0x0d || 0x0c || 0x0b || 0x85 || 0xa0 => true,
        _ => false,
      };
      if (!possible) return null;
    }
    if (isBlankLine(rawLine)) return null;
    final title = normalizeInline(rawLine);
    if (title.isEmpty || title.length > maxHeadingLength) return null;

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

    final volume = _volume.firstMatch(title);
    final match =
        volume ?? _chapter.firstMatch(title) ?? _english.firstMatch(title);
    if (match == null) return null;
    // 例如「第二章 回城」可以是标题，「第二章的事」仍留在正文里。
    if (indented && match.end < title.length && title[match.end] != ' ') {
      return null;
    }
    return TxtHeading(
      lineIndex: lineIndex,
      title: title,
      kind: volume != null ? TxtHeadingKind.volume : TxtHeadingKind.chapter,
    );
  }

  static TxtHeading? _matchCombined(String rawLine, int lineIndex) {
    // 编码后的中点比实际字符长。先低成本筛掉普通段落，再检查显示长度。
    if (rawLine.length > maxHeadingLength * 3) return null;
    final first = rawLine.indexOf('第');
    if (first < 0 || rawLine.indexOf('第', first + 1) < 0) return null;
    final title = normalizeInline(rawLine).replaceAllMapped(
      _encodedMiddleDot,
      (match) => match[0]!.endsWith('12539;') ? '・' : '·',
    );
    if (title.length > maxHeadingLength ||
        _sentencePunctuation.hasMatch(title)) {
      return null;
    }
    final match = _combined.firstMatch(title);
    if (match == null) return null;
    final volume = match.namedGroup('volume')!;
    final volumeName = match.namedGroup('volumeName')?.trim();
    return TxtHeading(
      lineIndex: lineIndex,
      title: match.namedGroup('chapter')!,
      kind: TxtHeadingKind.chapter,
      partTitle: match.namedGroup('part')?.trim(),
      volumeTitle: volumeName == null || volumeName.isEmpty
          ? volume
          : '$volume·$volumeName',
    );
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
