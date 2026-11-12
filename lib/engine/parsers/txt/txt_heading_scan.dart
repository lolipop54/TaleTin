import '../../normalization/text_normalizer.dart';
import 'txt_chapter_rule.dart';

/// 在顺序扫描时用章号和发布结构确认较模糊的章题，回放前段也用同一规则。
class TxtHeadingScan {
  TxtHeadingScan(this.rule);

  final TxtChapterRule rule;
  bool _afterBlank = true;
  bool _bareChapterStyle = false;
  ({int number, String unit, bool arabic})? _expected;
  ({int first, int last})? _range;
  TxtHeading? _lastChapter;
  bool _onlyHeaderNoise = true;
  bool _sawHeaderNoise = false;
  int? _postedNumber;
  int? _lastPostedTitleNumber;
  int _postedAt = 0;
  bool _postedTitleFound = false;
  String _postedUnit = '章';
  String? _splitFoldTitle, _splitFoldFirst;

  static const _digits = r'(?:[0-9０-９]+|[〇○零一二三四五六七八九十百千万萬两兩廿卅卌]+)';
  static final _chapterRange = RegExp(
    '^第?($_digits)章 *(?:至|到|[-－—~～]) *第?($_digits)章\$',
  );
  static final _bareNumber = RegExp('^($_digits)(.+)\$');
  static final _release = RegExp(
    '^【[^】]{1,20}】 *(?<volume>第 *$_digits *卷 +[^【】。；]+?) +(?<issue>[0-9]{1,5})(?: *[（(]全书完[）)])?\$',
  );
  static final _date = RegExp(r'(?:19|20)[0-9]{2}年[0-9]{1,2}月[0-9]{1,2}日');
  static final _pairedTitle = RegExp(
    r'^(?:第\s*)?[0-9０-９]+\s*章[·・][\u3400-\u9fff]{4}[，、·・][\u3400-\u9fff]{4}',
  );
  static final _fourIdeographs = RegExp(r'^[\u3400-\u9fff]{4}$');
  static final _proseTail = RegExp(
    r'[。；：:“”]|^(?:多年|几个|[年月日天][来來前后後内內]|[个個名只位条條件里歲岁](?:[，、]|$))',
  );

  TxtHeading? read(String raw, int index, {required bool blank}) {
    final afterBlank = _afterBlank;
    _afterBlank = blank;
    if (blank) return null;
    if (rule.customPattern != null) return rule.matchLine(raw, index);

    final indented = TxtChapterRule.hasIndent(raw);
    final short = raw.length <= 90 ? raw.trimLeft() : '';
    final release = short.startsWith('【')
        ? _release.firstMatch(short.trimRight())
        : null;
    if (release != null) {
      final number = int.parse(release.namedGroup('issue')!);
      _postedNumber = number;
      _postedAt = index;
      _postedTitleFound = _lastPostedTitleNumber == number;
      _splitFoldTitle = _splitFoldFirst = null;
      // 抓取稿有时把正式标题与帖号错开一位，后一帖只剩网页尾部。
      if (_postedTitleFound) return null;
      return TxtHeading(
        lineIndex: index,
        title: '第$number$_postedUnit',
        kind: TxtHeadingKind.chapter,
        volumeTitle: release.namedGroup('volume')!,
      );
    }
    if (_postedNumber case final number?) {
      // 发布行给出可靠的分卷和顺序。发布行后的正式标题补充名称；
      // 正文里的同名目录、预告或粘连原文仍留在各自的字节区间内。
      if (index - _postedAt > 120) return null;
      if (_splitFoldTitle case final shortTitle?) {
        final line = short.trimRight();
        if (_fourIdeographs.hasMatch(line)) {
          if (_splitFoldFirst case final first?) {
            _splitFoldTitle = _splitFoldFirst = null;
            return _rename(index, '$shortTitle $first $line');
          }
          _splitFoldFirst = line;
        } else {
          _splitFoldTitle = _splitFoldFirst = null;
        }
        return null;
      }
      if (_postedTitleFound) return null;
      final title = _postedTitle(
        raw,
        number,
        allowNext: index - _postedAt <= 8,
      );
      if (title == null) return null;
      _postedTitleFound = true;
      final numbered = TxtChapterRule.numberedChapter(title)!;
      _lastPostedTitleNumber = numbered.number;
      if (numbered.unit == '折') _postedUnit = '折';
      if (numbered.unit == '折' && numbered.end == title.length) {
        _splitFoldTitle = title;
      }
      return _rename(index, title);
    }

    final rangeMatch = short.contains('章')
        ? _chapterRange.firstMatch(short.trimRight())
        : null;
    if (rangeMatch != null) {
      final first = TxtChapterRule.parseNumber(rangeMatch[1]!)!;
      final last = TxtChapterRule.parseNumber(rangeMatch[2]!)!;
      if (last >= first && last - first <= 30) {
        _range = (first: first, last: last);
        _expected = (
          number: first,
          unit: '章',
          arabic: RegExp(r'^[0-9０-９]').hasMatch(rangeMatch[1]!),
        );
        return null;
      }
    }
    final expected = _expected;
    final range = _range;
    final inRange =
        range != null &&
        expected != null &&
        expected.number >= range.first &&
        expected.number <= range.last;
    var heading = rule.matchLine(
      raw,
      index,
      afterBlankLine: afterBlank,
      expected: expected,
      inChapterRange: inRange,
      usesCompactChapterTitles: _bareChapterStyle,
    );
    if (heading == null &&
        expected?.unit == '章' &&
        (_bareChapterStyle && !indented || inRange) &&
        short.isNotEmpty &&
        short.length <= TxtChapterRule.maxHeadingLength) {
      final line = normalizeInline(short);
      final bare = _bareNumber.firstMatch(line);
      if (bare != null && TxtChapterRule.numberedChapter(line) == null) {
        for (var length = bare[1]!.length; length >= 1; length--) {
          final prefix = line.substring(0, length);
          if (TxtChapterRule.parseNumber(prefix) != expected!.number) continue;
          final tail = line.substring(length);
          if (!_proseTail.hasMatch(tail)) {
            heading = TxtHeading(
              lineIndex: index,
              title: '$prefix章$tail',
              kind: TxtHeadingKind.chapter,
            );
          }
          break;
        }
      }
    }
    if (heading == null) {
      if (_onlyHeaderNoise) {
        final noise = short.startsWith('-欢迎您') || short.startsWith('－欢迎您');
        _onlyHeaderNoise = noise;
        _sawHeaderNoise |= noise;
      }
      return null;
    }
    if (heading.kind == TxtHeadingKind.volume) {
      _expected = null;
      _lastChapter = null;
      return heading;
    }
    final previous = _lastChapter;
    if (previous != null &&
        heading.title == previous.title &&
        _onlyHeaderNoise &&
        index - previous.lineIndex <= 8) {
      // 无正文的连续同题由现有建章逻辑合并。若中间只有发布站欢迎语，
      // 保留原文的连续字节范围，不再用第二个章题开章。
      if (_sawHeaderNoise) return null;
      if (previous.volumeTitle != null && heading.volumeTitle == null) {
        return heading;
      }
    }
    final numbered = TxtChapterRule.numberedChapter(heading.title);
    if (numbered != null) {
      _expected = (
        number: numbered.number + 1,
        unit: numbered.unit,
        arabic: numbered.arabic,
      );
      _bareChapterStyle |=
          numbered.unit == '章' && !heading.title.startsWith('第');
    } else {
      _expected = null;
    }
    _lastChapter = heading;
    _onlyHeaderNoise = true;
    _sawHeaderNoise = false;
    return heading;
  }

  static TxtHeading _rename(int index, String title) => TxtHeading(
    lineIndex: index,
    title: title,
    kind: TxtHeadingKind.chapter,
    revisesTitle: true,
  );

  static String? _postedTitle(
    String raw,
    int number, {
    required bool allowNext,
  }) {
    final start = raw.trimLeft();
    if (start.isEmpty) return null;
    final prefix = start.length > 160 ? start.substring(0, 160) : start;
    final date = _date.firstMatch(prefix);
    var title = date != null
        ? _pairedTitle.stringMatch(prefix.substring(date.end).trimLeft()) ??
              normalizeInline(prefix.substring(0, date.start))
        : prefix.length <= 80
        ? normalizeInline(prefix)
        : '';
    if (title.startsWith('【') && title.endsWith('】')) {
      title = title.substring(1, title.length - 1);
    }
    final chapter = TxtChapterRule.numberedChapter(title);
    return chapter != null &&
            (chapter.number == number ||
                allowNext &&
                    chapter.unit == '折' &&
                    chapter.number == number + 1) &&
            (chapter.unit == '折' || chapter.unit == '章') &&
            title.length <= TxtChapterRule.maxHeadingLength &&
            !title.contains('。') &&
            !title.contains('；')
        ? title
        : null;
  }
}
