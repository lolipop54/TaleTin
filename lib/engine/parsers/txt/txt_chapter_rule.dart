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
    this.revisesTitle = false,
    this.requiresBody = false,
  });

  /// 标题在文本里的行号（0 起）
  final int lineIndex;
  final String title;
  final TxtHeadingKind kind;

  /// 合写章题自带的篇名（可省略）和卷名。
  final String? partTitle;
  final String? volumeTitle;

  /// 发布行后的正式标题只更新章名，原行仍可能带有正文。
  final bool revisesTitle;

  /// 单独的序、跋和结尾标记有后续正文时才作为章节。
  final bool requiresBody;
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

  static const _digits = r'(?:[0-9０-９]+|[〇○零一二三四五六七八九十百千万萬两兩廿卅卌]+)';
  static const _number = '第\\s*$_digits\\s*';
  static const _chapterUnits = '章节節回幕折';
  static final RegExp _volume = RegExp('^(?:$_number)[卷部篇册冊]');
  static final RegExp _chapter = RegExp(
    '^(第\\s*)?($_digits)\\s*([$_chapterUnits])',
  );
  static final RegExp _english = RegExp(r'^(Chapter|CHAPTER)\s+[0-9IVXLC]+');
  static final RegExp _encodedMiddleDot = RegExp(
    r'(?:(?:&#0*38;|&amp;)#|&#)(?:0*183|x0*b7|0*12539);|&middot;',
    caseSensitive: false,
  );
  static final RegExp _combined = RegExp(
    r'^(?:(?<part>[^·・•]+[篇部])\s*[·・•]\s*)?'
    '(?<volume>$_number[卷部篇册冊])'
    r'(?<volumeName>.*?)'
    '(?<chapter>$_number[$_chapterUnits日].*|(?:序[章幕]|[终終][章幕]|尾[声聲]).*)\$',
  );

  /// 句号、分号仍作为正文线索；问号、叹号、省略号常见于独立章题。
  static final RegExp _sentencePunctuation = RegExp(r'[。；]');
  static final RegExp _volumeClosing = RegExp(
    r'[总總][结結][兼与與及和]?感言|[卷篇]末(?:[总總][结結]|感言|小[结結])|[（(·・ ，,》」】][终終完][）)]?$|^(?:完|[终終]|[结結]束|[总總][结結]|感言|小[结結]|[后後][记記])$',
  );
  static final RegExp _special = RegExp(
    r'^(?:序章|序幕|序言|前言|前记|前記|楔子|引子|引言|(?:最[终終]|[终終])[章幕篇]|尾[声聲]|[后後]記|[后後]记|跋|完本感言|完[结結]感言|[结結][语語])'
    r'(?:$|[ :：·・、—－\-（(《【].{0,34}$)',
  );
  static final RegExp _ending = RegExp(r'^大[结結]局(?![了时時是后後])');
  static final RegExp _extra = RegExp(
    '^(?:番外(?:前传|前傳)\\s+$_number[$_chapterUnits]|番外(?:之)?$_digits(?: |[：:·・、—－-]|\$)|番外[ :：·・—－-]|番外.{1,18}外[传傳][（(](?:$_digits|完)[）)])',
  );
  static final RegExp _startsHeading = RegExp(
    r'^[ \t\n\r\x0b\x0c\u0085\u3000\u00a0]*[第0-9０-９〇○零一二三四五六七八九十百千万萬两兩廿卅卌C【序前楔引最终終尾后後跋完结結大番]',
  );
  static final RegExp _attachedProse = RegExp(r'^(?:的|[里裡时時][，,]|[后後前]的)');

  /// 判断一行是否为标题；不是则返回 null。
  ///
  /// 缩进章题用空行、编号边界或已确认的连续章号判断。
  TxtHeading? matchLine(
    String rawLine,
    int lineIndex, {
    bool afterBlankLine = false,
    ({int number, String unit, bool arabic})? expected,
    bool inChapterRange = false,
    bool usesCompactChapterTitles = false,
  }) {
    if (rawLine.isEmpty) return null;
    final pattern = customPattern;
    final indented = hasIndent(rawLine);
    if (pattern == null &&
        (afterBlankLine || !indented) &&
        rawLine.length <= maxHeadingLength * 3 &&
        rawLine.contains('第') &&
        (rawLine.contains('卷') ||
            rawLine.contains('篇') ||
            rawLine.contains('部') ||
            rawLine.contains('册') ||
            rawLine.contains('冊'))) {
      final combined = _matchCombined(rawLine, lineIndex);
      if (combined != null) return combined;
    }
    if (rawLine.length > maxHeadingLength * 3 ||
        (pattern != null && indented) ||
        (pattern == null && !_startsHeading.hasMatch(rawLine))) {
      return null;
    }
    var title = normalizeInline(rawLine);
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

    final bracketed = title.startsWith('【') && title.endsWith('】');
    if (bracketed) title = title.substring(1, title.length - 1).trim();
    final number = numberedChapter(title);
    final follows =
        number != null &&
        expected != null &&
        number.number == expected.number &&
        number.unit == expected.unit &&
        number.arabic == expected.arabic;
    final volume = _volume.firstMatch(title);
    if (_sentencePunctuation.firstMatch(title) case final punctuation?) {
      // 分号可以分隔成对的卷名。章名以句号结尾时，还要有独立的
      // 标题行、明确的编号分隔和连续章号，避免切开正文里的完整句子。
      final standalone = afterBlankLine && !indented;
      final volumeTitle =
          standalone &&
          volume != null &&
          title.startsWith(' ', volume.end) &&
          !title.endsWith('；') &&
          !title.contains('。');
      final chapterTitle =
          follows &&
          !title.contains('；') &&
          (!title.endsWith('。') ||
              standalone &&
                  title.startsWith(' ', number.end) &&
                  punctuation.start == title.length - 1);
      if (!volumeTitle && !chapterTitle) return null;
    }

    if (_special.hasMatch(title) ||
        (!indented && (_ending.hasMatch(title) || _extra.hasMatch(title)))) {
      return !indented || afterBlankLine
          ? TxtHeading(
              lineIndex: lineIndex,
              title: title,
              kind: TxtHeadingKind.chapter,
              requiresBody: true,
            )
          : null;
    }

    if (volume != null) {
      final tail = title.substring(volume.end);
      if (_volumeClosing.hasMatch(tail.trim())) {
        // 卷尾说明可供目录跳转，但不能开启另一卷。
        return (!indented || afterBlankLine) && tail.contains('感言')
            ? TxtHeading(
                lineIndex: lineIndex,
                title: title,
                kind: TxtHeadingKind.chapter,
                requiresBody: true,
              )
            : null;
      }
      if (indented && (!afterBlankLine || !separated(tail))) return null;
      return TxtHeading(
        lineIndex: lineIndex,
        title: title,
        kind: TxtHeadingKind.volume,
      );
    }
    if (number != null) {
      final tail = title.substring(number.end);
      if (!follows && _attachedProse.hasMatch(tail)) return null;
      if (indented &&
          !(afterBlankLine && (bracketed || separated(tail))) &&
          !(follows &&
              (number.arabic && separated(tail) ||
                  inChapterRange ||
                  usesCompactChapterTitles &&
                      number.unit == '章' &&
                      tail.isNotEmpty))) {
        return null;
      }
      return TxtHeading(
        lineIndex: lineIndex,
        title: title,
        kind: TxtHeadingKind.chapter,
      );
    }
    return !indented && _english.hasMatch(title)
        ? TxtHeading(
            lineIndex: lineIndex,
            title: title,
            kind: TxtHeadingKind.chapter,
          )
        : null;
  }

  static TxtHeading? _matchCombined(String rawLine, int lineIndex) {
    // 编码后的中点比实际字符长。先低成本筛掉普通段落，再检查显示长度。
    if (rawLine.length > maxHeadingLength * 3) return null;
    final first = rawLine.indexOf('第');
    if (first < 0) return null;
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
    final chapter = match.namedGroup('chapter')!;
    final volumeName = match
        .namedGroup('volumeName')!
        .replaceAll(RegExp(r'^[\s·・•]+|[\s·・•]+$'), '');
    if (_volumeClosing.hasMatch(volumeName)) return null;
    return TxtHeading(
      lineIndex: lineIndex,
      title: chapter,
      kind: TxtHeadingKind.chapter,
      partTitle: match.namedGroup('part')?.trim(),
      volumeTitle: volumeName.isEmpty ? volume : '$volume·$volumeName',
      requiresBody: _special.hasMatch(chapter) || chapter.startsWith('终章'),
    );
  }

  static bool separated(String tail) =>
      tail.isEmpty || ' :：·・、—－-'.contains(tail[0]);

  static ({int number, String unit, bool arabic, int end})? numberedChapter(
    String title,
  ) {
    final match = _chapter.firstMatch(title);
    if (match == null) return null;
    final digits = match[2]!;
    final arabic =
        digits.codeUnitAt(0) >= 0x30 && digits.codeUnitAt(0) <= 0x39 ||
        digits.codeUnitAt(0) >= 0xff10 && digits.codeUnitAt(0) <= 0xff19;
    final number = parseNumber(digits);
    return number == null
        ? null
        : (number: number, unit: match[3]!, arabic: arabic, end: match.end);
  }

  static final RegExp _volumeNumber = RegExp('^第\\s*($_digits)\\s*([卷部篇册冊])');
  static String volumeIdentity(String title) {
    final match = _volumeNumber.firstMatch(title);
    if (match == null) return title;
    return '${parseNumber(match[1]!) ?? match[1]}${match[2]}';
  }

  static int? parseNumber(String value) {
    const digits = {
      '零': 0,
      '〇': 0,
      '○': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '兩': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const units = {'十': 10, '百': 100, '千': 1000, '万': 10000, '萬': 10000};
    var total = 0, section = 0, current = 0;
    var hasDigit = false;
    for (final code in value.codeUnits) {
      final char = String.fromCharCode(code);
      final digit =
          digits[char] ??
          (code >= 0x30 && code <= 0x39
              ? code - 0x30
              : code >= 0xff10 && code <= 0xff19
              ? code - 0xff10
              : null);
      if (digit != null) {
        current = current * 10 + digit;
        hasDigit = true;
        continue;
      }
      final tens = switch (char) {
        '廿' => 20,
        '卅' => 30,
        '卌' => 40,
        _ => 0,
      };
      if (tens != 0) {
        section += tens;
        continue;
      }
      final unit = units[char];
      if (unit == null) return null;
      if (unit == 10000) {
        total +=
            (section + (hasDigit ? current : (section == 0 ? 1 : 0))) * unit;
        section = 0;
      } else {
        section += (hasDigit ? current : 1) * unit;
      }
      current = 0;
      hasDigit = false;
    }
    return total + section + current;
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
