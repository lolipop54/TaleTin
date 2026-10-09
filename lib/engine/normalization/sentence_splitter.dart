/// 句子切分（离线听书实现计划 6.1、6.1.2）。
///
/// 输入是**一块**标准化正文（`blockTextOf(block)`），输出是这块文本里的句子范围：
/// - 偏移是源文本上的 UTF-16 code unit 下标，且一律落在字素簇边界上，
///   不会把 emoji、代理对或组合字符切在中间；
/// - 源文本一个字符都不改、不删（不做破坏性 trim / replace），范围按顺序铺满整块，
///   这样朗读位置才能原样换算回 Locator；
/// - 首尾空白不送给引擎（引擎会把空白当停顿），但范围保留，
///   [SentenceSpan.textStart] 记录真正开始朗读的位置，范围回调的偏移要靠它换算回原文。
///
/// 块末就是自然句末：切分只看一块文本，不会把相邻两段硬连成一句。
library;

import 'package:characters/characters.dart';

/// 一句在源文本里的范围。
class SentenceSpan {
  const SentenceSpan({
    required this.start,
    required this.end,
    required this.textStart,
    required this.text,
  });

  /// 源文本里的完整范围起点（含句首空白），右开区间
  final int start;

  /// 源文本里的范围终点（含句末符号和紧随其后的收尾引号/括号）
  final int end;

  /// 送给引擎的第一个字符在源文本里的位置（跳过句首空白）
  final int textStart;

  /// 送给引擎的文本（已去掉首尾空白），保证非空
  final String text;

  /// 本句在源文本里的长度（含被剪掉的空白）
  int get length => end - start;

  /// 送引擎文本的终点（右开）
  int get textEnd => textStart + text.length;

  /// [offset] 是否落在本句范围内（含句首空白）
  bool containsOffset(int offset) => offset >= start && offset < end;

  @override
  String toString() =>
      'SentenceSpan($start..$end "${text.length > 12 ? '${text.substring(0, 12)}…' : text}")';
}

/// 句末符号；连续出现（如 `……`、`?!`）算同一个句末。
const Set<String> _sentenceEnders = {'。', '！', '？', '!', '?', '．', '…'};

/// 句末符号后面紧跟的收尾符号，并入前一句（`。”`、`？”`、`。）`）。
const Set<String> _trailingPunctuation = {
  '”', '’', '」', '』', '》', '〉', '】', '〕', '）', ')', ']', '］', '｝', '}',
  '"', "'",
};

/// 常见英文缩写：这里的句点属于缩写本身，不是句末。
///
/// 只收录独立成词后几乎不会出现在句末的写法；宁可多断句（最多重读一点），
/// 也不要把两句话粘成一句读。
const Set<String> _abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'st', 'jr', 'sr', 'vs',
  'etc', 'e.g', 'i.e', 'vol', 'fig', 'al', 'inc', 'ltd', 'co', 'dept', 'approx',
};

/// 把一块标准化正文切成句子，按顺序返回；没有可读文本时返回空列表。
///
/// 纯空白块、只有标点的块都会返回空列表（调用方据此类推跳过这一块）。
List<SentenceSpan> splitSentences(String source) {
  if (source.isEmpty) return const [];

  // 字素簇起点表：切点只允许落在这些下标上。
  final clusters = <String>[];
  final offsets = <int>[];
  var offset = 0;
  for (final cluster in source.characters) {
    clusters.add(cluster);
    offsets.add(offset);
    offset += cluster.length;
  }

  final spans = <SentenceSpan>[];
  var sentenceStart = 0;
  var i = 0;
  while (i < clusters.length) {
    if (!_endsSentenceAt(clusters, i)) {
      i++;
      continue;
    }
    // 把句末符号的连续串和紧随的收尾引号/括号一起并进这一句
    var boundary = i + 1;
    while (boundary < clusters.length && _absorbsIntoBoundary(clusters, boundary)) {
      boundary++;
    }
    final spanEnd =
        boundary >= clusters.length ? source.length : offsets[boundary];
    _addSpan(spans, source, sentenceStart, spanEnd);
    sentenceStart = spanEnd;
    i = boundary;
  }

  // 最后一段没有句末符号也照样成句（块末是自然边界）
  if (sentenceStart < source.length) {
    _addSpan(spans, source, sentenceStart, source.length);
  }
  return spans;
}

/// 找到 [offset] 所在的句子下标。
///
/// 偏移落在句间空白里时取它**后面**那一句（宁可重读一小段，也不跳过没确认的内容）；
/// 落在最后一句之后返回 `spans.length`，表示这段文本已无可读内容，
/// 由调用方决定去下一块。空列表同样返回 0（等于长度），调用方不必特判。
int sentenceIndexAt(List<SentenceSpan> spans, int offset) {
  for (var i = 0; i < spans.length; i++) {
    if (offset < spans[i].end) return i;
  }
  return spans.length;
}

/// 把 [start, end) 收成一句；去掉首尾空白后没有内容就不产出。
void _addSpan(List<SentenceSpan> spans, String source, int start, int end) {
  final raw = source.substring(start, end);
  final text = raw.trim();
  if (text.isEmpty) return;
  final leading = raw.length - raw.trimLeft().length;
  spans.add(
    SentenceSpan(
      start: start,
      end: end,
      textStart: start + leading,
      text: text,
    ),
  );
}

/// [index] 处的字素簇是否结束一句话。
bool _endsSentenceAt(List<String> clusters, int index) {
  final cluster = clusters[index];
  if (cluster == '.') return _dotEndsSentence(clusters, index);
  return _sentenceEnders.contains(cluster);
}

/// 句末符号串还会往后吸哪些字素簇：收尾引号/括号一定吸，句末符号继续吸。
bool _absorbsIntoBoundary(List<String> clusters, int index) {
  if (_trailingPunctuation.contains(clusters[index])) return true;
  return _endsSentenceAt(clusters, index);
}

/// 英文句点到底算不算句末：小数点与常见缩写不算，连续多个点按省略号算句末。
bool _dotEndsSentence(List<String> clusters, int index) {
  var after = index + 1;
  while (after < clusters.length && clusters[after] == '.') {
    after++;
  }
  if (after - index > 1) return true;

  if (index > 0 &&
      after < clusters.length &&
      _isAsciiDigit(clusters[index - 1]) &&
      _isAsciiDigit(clusters[after])) {
    return false;
  }
  return !_isAbbreviationBefore(clusters, index);
}

/// 句点前面是不是收录过的英文缩写。
bool _isAbbreviationBefore(List<String> clusters, int index) {
  var start = index;
  while (start > 0 && _isAsciiLetterOrDot(clusters[start - 1])) {
    start--;
  }
  if (start == index) return false;
  return _abbreviations.contains(
    clusters.sublist(start, index).join().toLowerCase(),
  );
}

bool _isAsciiDigit(String cluster) =>
    cluster.length == 1 &&
    cluster.codeUnitAt(0) >= 0x30 &&
    cluster.codeUnitAt(0) <= 0x39;

bool _isAsciiLetterOrDot(String cluster) {
  if (cluster == '.') return true;
  if (cluster.length != 1) return false;
  final code = cluster.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
}
