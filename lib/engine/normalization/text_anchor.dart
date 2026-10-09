/// 原书排版模式 ↔ 简化模式的位置换算（设计文档 6.3、原书排版模式实现计划 3.6）。
///
/// 原书模式的 WebView 报告的是「页序 + 章内比例 + 页首文字」，而**持久位置永远是
/// Dart 侧的 `Locator`**（页序与比例只是排版的临时结果，不落盘）。这个文件负责把
/// 页面文字换算回标准化正文里的位置：
///
/// 1. **优先按文字找**：把页首文字与正文都去掉空白后做子串匹配——这是最准的一条路，
///    模式切换、以后 TTS 的句段定位都走它；
/// 2. **比例兜底**：文字匹配不上（排版差异、文字被截断、页面只有图片）时，按
///    「章内比例 × 章内文本长度」折算。
///
/// 匹配用的坐标是**标准化正文的 UTF-16 偏移**，与 [LocatorMapper] 同一套口径：
/// 每块文本长度再加 1（空块也有位置权重）。
library;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import 'locator_mapper.dart';

/// 去空白后取多少个字符去做匹配。
///
/// 取少了容易撞上重复的句子（「他说。」这种），取多了会被 WebView 的截断
/// （host.js 只报页首 60 字）与两边的空白折叠差异影响。
const int kAnchorMatchChars = 24;

/// 匹配不上时逐步缩短的阶梯：容忍个别字符差异（首字缩进、软连字符、错字）。
const List<int> _matchLadder = [kAnchorMatchChars, 12, 8, _minMatchChars];

/// 太短的片段不足以定位（「他说」这种到处都是），不参与匹配。
const int _minMatchChars = 6;

/// 按页首文字在标准化正文里找位置；找不到返回 null（调用方用比例兜底）。
///
/// [fragment] 是原书页面开头的文字（可能带空白、可能被截断）。
Locator? locatorForTextFragment({
  required ChapterContent content,
  required String bookId,
  required int contentVersion,
  required String chapterId,
  required String fragment,
}) {
  final needle = _compact(fragment);
  if (needle.length < _minMatchChars) return null;
  final mapper = LocatorMapper(
    bookId: bookId,
    contentVersion: contentVersion,
    chapterId: chapterId,
  );
  // 先试长片段（最准），不行再缩短：短片段命中概率高但位置可能偏
  for (final probe in _probesOf(needle)) {
    for (final block in content.blocks) {
      final text = blockTextOf(block);
      final compact = _compact(text);
      if (compact.length < probe.length) continue;
      final index = compact.indexOf(probe);
      if (index < 0) continue;
      return mapper.at(block, _offsetOfCompactIndex(text, index));
    }
  }
  return null;
}

/// 由长到短的候选片段（去重）。
///
/// 页首文字本身可能就比阶梯第一步短（比如只报了 7 个字），
/// 这时第一轮就该用整个片段，而不是一个都不试。
List<String> _probesOf(String needle) {
  final probes = <String>[];
  for (final length in _matchLadder) {
    if (length <= 0) continue;
    final probe =
        needle.length <= length ? needle : needle.substring(0, length);
    if (probe.length < _minMatchChars) continue;
    if (probes.isNotEmpty && probes.last == probe) continue;
    probes.add(probe);
  }
  return probes;
}

/// 按章内比例取位置（文字匹配不上时的兜底）。
///
/// 比例是「内容流比例」，与排版无关；折算时用与 [LocatorMapper.totalLength]
/// 相同的口径，保证两种模式的百分比可以对上。
Locator? locatorForFraction({
  required ChapterContent content,
  required String bookId,
  required int contentVersion,
  required String chapterId,
  required double fraction,
}) {
  if (content.blocks.isEmpty) return null;
  final mapper = LocatorMapper(
    bookId: bookId,
    contentVersion: contentVersion,
    chapterId: chapterId,
  );
  final total = mapper.totalLength(content.blocks);
  if (total <= 0) return null;
  final target = (fraction.clamp(0.0, 1.0) * total).round();
  var consumed = 0;
  for (final block in content.blocks) {
    final text = blockTextOf(block);
    // 每块占 text.length + 1（与 totalLength 同口径）
    if (consumed + text.length + 1 > target) {
      final offset = (target - consumed).clamp(0, text.length);
      return mapper.at(block, offset);
    }
    consumed += text.length + 1;
  }
  // 落在末尾之后：取最后一块的末尾
  final last = content.blocks.last;
  return mapper.at(last, blockTextOf(last).length);
}

/// 章内比例：`Locator` → 0–1，与 [locatorForFraction] 互逆。
///
/// 注意 `Locator.utf16Offset` 是**块内**偏移，不是章内偏移：要先把这一块之前
/// 所有块的累计长度加回去，再除以章内总长。漏掉这一步，位置在靠后的块里时
/// 算出来的比例会接近 0，直接以原书模式打开这本书就会跳回章首（实测踩过）。
double fractionOfLocator({
  required ChapterContent content,
  required String bookId,
  required int contentVersion,
  required String chapterId,
  required Locator locator,
}) {
  final mapper = LocatorMapper(
    bookId: bookId,
    contentVersion: contentVersion,
    chapterId: chapterId,
  );
  final total = mapper.totalLength(content.blocks);
  if (total <= 0) return 0;
  var consumed = 0;
  for (final block in content.blocks) {
    final text = blockTextOf(block);
    if (block.id == locator.blockId) {
      final offset = locator.utf16Offset.clamp(0, text.length);
      return ((consumed + offset) / total).clamp(0.0, 1.0);
    }
    consumed += text.length + 1;
  }
  // 块 ID 不在这一章（例如内容版本变了）：按章首处理，由调用方再校正
  return 0;
}

/// 去掉全部空白字符：原书页面的换行/缩进与标准化正文的口径不同，
/// 去掉空白后再比才不会因为一个换行就匹配失败。
String _compact(String text) => text.replaceAll(_whitespace, '');

final _whitespace = RegExp(r'\s+');

/// 去空白后的下标 → 原文下标。
///
/// 例：`"一 二 三"` 去空白后是 `"一二三"`，下标 1 对应原文下标 2。
int _offsetOfCompactIndex(String text, int compactIndex) {
  var seen = 0;
  for (var i = 0; i < text.length; i++) {
    if (_whitespace.hasMatch(text[i])) continue;
    if (seen == compactIndex) return i;
    seen++;
  }
  return text.length;
}
