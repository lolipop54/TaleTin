/// 把一章标准化正文拆成朗读单元（离线听书实现计划 6.1、6.3）。
///
/// 这里只做纯计算：不读文件、不碰 Flutter，输入是已经读好的 `ChapterContent`。
/// 一份索引只覆盖**一个正文文件**，不一次建整本书的单元队列；
/// 播放时再用 [SpeechUnitIndex.window] 只取当前和后面有限几个单元。
///
/// 标点、空白的口径全部来自 `sentence_splitter.dart` 和 `locator_mapper.dart`：
/// 文本偏移与排版、书签、笔记用的是同一套，不为听书另立一套正文。
library;

import 'package:characters/characters.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../../domain/models/speech_unit.dart';
import 'locator_mapper.dart';
import 'sentence_splitter.dart';

/// 单个单元的文本上限（UTF-16 单元）。
///
/// 引擎自己的上限是几千（Android `getMaxSpeechInputLength()`，真机实测常见 4000），
/// 这里主动收紧到 200：短段才能在暂停、换章、定时到点时及时停下，
/// 缺范围回调时续读位置的偏差也小得多，高亮跟随也更容易跨页。
/// 属于可调工程参数（实现计划 6.1.3）。
const int kSpeechUnitMaxLength = 200;

/// 播放队列一次最多准备多少个单元（实现计划 6.1.6）。
const int kSpeechUnitWindow = 20;

/// 长句拆分的候选断点：断在这些字之后，语义和听感都更自然。
const Set<String> _breakChars = {
  '，', ',', '、', '；', ';', '：', ':', '。', '！', '？', '!', '?', '…', '—',
};

/// 把一章正文拆成朗读单元。
///
/// 图片、分隔线和没有文字的块跳过；标题、段落等有文字的块按正文顺序读。
/// 这里只拆正文；目录中缺少正文对应的章题由听书数据入口补上并去重。
SpeechUnitIndex buildSpeechUnits({
  required String bookId,
  required int contentVersion,
  required String logicalChapterId,
  required ChapterContent content,
  int maxUnitLength = kSpeechUnitMaxLength,
}) {
  final mapper = LocatorMapper(
    bookId: bookId,
    contentVersion: contentVersion,
    chapterId: content.chapterId,
  );
  final units = <SpeechUnit>[];
  final blockOrder = <String, int>{};

  for (var order = 0; order < content.blocks.length; order++) {
    final block = content.blocks[order];
    if (!isSpeakableBlock(block)) continue;
    blockOrder[block.id] = order;

    final text = blockTextOf(block);
    final spans = splitSentences(text);
    for (var s = 0; s < spans.length; s++) {
      final span = spans[s];
      final sentenceId = '${block.id}#$s';
      final pieces = splitLongSentence(span.text, maxUnitLength);
      for (var p = 0; p < pieces.length; p++) {
        final piece = pieces[p];
        units.add(
          SpeechUnit(
            id: '$sentenceId.$p',
            bookId: bookId,
            contentVersion: contentVersion,
            logicalChapterId: logicalChapterId,
            text: span.text.substring(piece.start, piece.end),
            startLocator: mapper.at(block, span.textStart + piece.start),
            endLocator: mapper.at(block, span.textStart + piece.end),
            sentenceId: sentenceId,
            // 整句范围不带首尾空白，缺范围回调时续读位置就落在这段文本上
            sentenceText: span.text,
            sentenceStart: mapper.at(block, span.textStart),
            sentenceEnd: mapper.at(block, span.textEnd),
          ),
        );
      }
    }
  }
  return SpeechUnitIndex._(
    units: units,
    blockOrder: blockOrder,
    chapterId: content.chapterId,
  );
}

/// 把一段文本拆成不超过 [maxLength] 的若干段，返回各段在**这段文本内**的范围。
///
/// 优先在标点或空白之后断开；找不到合适断点就退到字素簇边界，
/// 绝不会把 emoji、代理对或组合字符切在中间。断点处的空白两端都不送引擎。
List<({int start, int end})> splitLongSentence(String text, int maxLength) {
  if (text.length <= maxLength) return [(start: 0, end: text.length)];

  final pieces = <({int start, int end})>[];
  var start = 0;
  while (text.length - start > maxLength) {
    final limit = start + maxLength;
    // 断点回溯的下限：太靠前的断点会让单元短得没意义
    final floor = start + maxLength ~/ 2;
    var end = _lastBreakAt(text, floor, limit);
    if (end < 0) end = snapToGrapheme(text, limit);
    // 断点前是空白就不送给引擎（是逗号这类标点则保留，听感上就该停在标点后）
    while (end > start && _isSpaceUnit(text[end - 1])) {
      end--;
    }
    if (end <= start) {
      // 兜底：断点被空白裁掉了，或者单个字素簇本身就长过上限。
      // 宁可让这一段超限，也不把字素簇切开、更不能原地打转。
      // （maxLength 默认 200，远大于任何字素簇，正常走不到这里。）
      end = _clusterBoundaryAfter(text, limit);
    }

    pieces.add((start: start, end: end));
    var next = end;
    while (next < text.length && _isSpaceUnit(text[next])) {
      next++;
    }
    start = next > end ? next : end;
  }
  if (start < text.length) pieces.add((start: start, end: text.length));
  return pieces;
}

/// 在 `[floor, limit)` 里找最靠后的断点，返回断点之后的位置；没有就返回 -1。
///
/// 只按 UTF-16 单元往回找，命中的一定是单单元的标点或空白，
/// 不会落到代理对中间。
int _lastBreakAt(String text, int floor, int limit) {
  for (var i = limit - 1; i >= floor; i--) {
    if (_isBreakChar(text[i])) return i + 1;
  }
  return -1;
}

/// [offset] 之后的第一个字素簇边界（至少比 [offset] 大）。
///
/// `snapToGrapheme` 是往前对齐的，这里要的是往后，所以单独写一个。
int _clusterBoundaryAfter(String text, int offset) {
  var index = 0;
  for (final cluster in text.characters) {
    index += cluster.length;
    if (index > offset) return index;
  }
  return text.length;
}

bool _isBreakChar(String unit) => _breakChars.contains(unit) || _isSpaceUnit(unit);

/// 单个 UTF-16 单元是不是空白（含全角空格、制表符；代理对半字一定不是）。
bool _isSpaceUnit(String unit) => unit.trim().isEmpty;

/// 这一块要不要出声。
///
/// 图片（没有文字）、分隔线、以及没有任何文字 runs 的块都跳过；
/// 脚注文本存在 `alt` 里、runs 为空，因此也不会插进正文朗读。
///
/// 逻辑章节索引判断「这段范围是不是空的」用的也是这个口径
/// （见 `domain/services/logical_chapter_index.dart`）。
bool isSpeakableBlock(ContentBlock block) =>
    block.runs.isNotEmpty &&
    block.kind != BlockKind.image &&
    block.kind != BlockKind.divider;

/// 一个正文文件的朗读单元索引。
class SpeechUnitIndex {
  SpeechUnitIndex._({
    required this.units,
    required this.chapterId,
    required Map<String, int> blockOrder,
  }) : _blockOrder = Map<String, int>.unmodifiable(blockOrder);
  /// 按朗读顺序排好的单元
  final List<SpeechUnit> units;

  /// 这份索引对应的正文文件
  final String chapterId;

  /// 块 ID → 它在章内的顺序，用于按 Locator 找起点
  final Map<String, int> _blockOrder;

  int get length => units.length;

  bool get isEmpty => units.isEmpty;

  /// 从 [from] 开始最多取 [count] 个单元；到末尾就少给，越界返回空表。
  List<SpeechUnit> window(int from, {int count = kSpeechUnitWindow}) {
    if (from < 0 || from >= units.length) return const [];
    final end = (from + count).clamp(0, units.length);
    return units.sublist(from, end);
  }

  /// 从 [locator] 所在句子的第一个单元开始。
  ///
  /// 锚点常常落在句子中间（段落里的阅读位置），但朗读要从整句开头起，
  /// 所以先找到锚点所在或其后最近的单元，再回到它那一句的开头
  /// （实现计划第 2 节：从当前阅读锚点所在句开始）。
  int startUnitIndexAt(Locator locator) {
    var index = _firstUnitAtOrAfter(locator);
    while (index > 0 &&
        index < units.length &&
        units[index].sentenceId == units[index - 1].sentenceId) {
      index--;
    }
    return index;
  }

  /// [locator] 所在或其后最近的单元下标；本章已无可读文本返回 [length]。
  int _firstUnitAtOrAfter(Locator locator) {
    final order = _blockOrder[locator.blockId];
    if (order == null) return units.length;
    for (var i = 0; i < units.length; i++) {
      final unitOrder = _blockOrder[units[i].startLocator.blockId]!;
      if (unitOrder < order) continue;
      if (unitOrder > order) return i;
      if (units[i].endLocator.utf16Offset > locator.utf16Offset) return i;
    }
    return units.length;
  }

  @override
  String toString() =>
      'SpeechUnitIndex($chapterId·${units.length}个单元)';
}
