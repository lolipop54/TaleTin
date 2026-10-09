/// 净化后 DOM 文本与标准化正文块之间的位置对照（离线听书实现计划 6.2）。
///
/// 目录锚点（`href#fragment`）和听书高亮要回答同一个问题：
/// 「DOM 里这个文字位置，对应标准化正文的哪一块、哪个 UTF-16 偏移」。
/// 这张表就是答案，而且**与产出正文块的遍历同时建立**，
/// 不靠把整章两段字符串做模糊对比（实现计划 6.2 明确禁止那种做法）。
///
/// 与 `xhtml_blocks.dart` 一致：同样式片段合并并折叠空白，
/// 各个样式 run 分别去掉首尾空白后再拼成块，不能按整块统一 trim。
library;

import 'package:html/dom.dart';

import '../../normalization/display_hyphens.dart';

/// 连续空白折叠成一个空格。
///
/// `<body>`、`<p>` 里的换行与缩进、`&nbsp;`、全角空格都按空白处理，
/// 与块构建共用同一条规则，避免两处口径不一致。
final RegExp _whitespace = RegExp(r'[\s\u00a0\u3000]+');

/// 把连续空白折成一个空格（块构建与对照表都用它）。
String collapseWhitespace(String raw) => raw.replaceAll(_whitespace, ' ');

/// 一个来源片段：某个 DOM 文本节点（或 `<br>` 这类合成片段）的原文。
class SourcePiece {
  const SourcePiece({
    required this.node,
    required this.raw,
    this.runIndex = 0,
    this.displayBreaks = const [],
  });

  /// 贡献这段文字的 DOM 文本节点；合成片段（如 `<br>` 折成的空格）为 null
  final Text? node;

  /// 节点原文，未做任何折叠
  final String raw;

  /// 所属的未裁剪正文 run；样式切换会开始一个新 run。
  final int runIndex;
  final List<int> displayBreaks;
}

/// 一个 DOM 文本节点在块文本里的落点。
class DomTextSegment {
  const DomTextSegment({
    required this.node,
    required this.blockId,
    required this.blockOffset,
    required this.hiddenLeading,
    required this.emittedLength,
    required this.absorbedLeading,
    required this.rawLength,
    this.displayBreaks = const [],
  });

  final Text node;
  final String blockId;

  /// 本片段第一个被输出的字符在块文本里的位置
  final int blockOffset;

  /// 被整块首部空白裁掉、没有输出的字符数
  final int hiddenLeading;

  /// 本片段在块文本里占的长度
  final int emittedLength;

  /// 开头的空格是否已经被上一片段输出（跨片段空白合并），此时不重复计一个
  final bool absorbedLeading;

  /// 节点原文长度（UTF-16），用于把任意偏移夹到合法范围
  final int rawLength;
  final List<int> displayBreaks;

  @override
  String toString() => 'DomTextSegment($blockId@$blockOffset+$emittedLength)';
}

/// 一次解析里所有文本节点到块位置的对照表。
class DomTextMap {
  DomTextMap._(this.segments, this._byNode, this._byBlock);

  /// 空的对照表：文档没有正文（没有 body）时使用。
  static final DomTextMap empty = DomTextMap._(const [], const {}, const {});

  /// 按文档顺序排好的片段
  final List<DomTextSegment> segments;

  final Map<Text, DomTextSegment> _byNode;
  final Map<String, List<DomTextSegment>> _byBlock;

  /// [node] 对应的片段；该节点没有输出文字（纯空白）时返回 null。
  DomTextSegment? segmentOf(Text node) => _byNode[node];

  /// 某一块的全部片段（正文顺序）。
  List<DomTextSegment> segmentsOfBlock(String blockId) =>
      _byBlock[blockId] ?? const [];

  /// 把 [node] 内部的原文偏移换算成块内 UTF-16 偏移。
  ///
  /// [sourceOffset] 超出节点长度时夹到两端；该节点没有输出时返回 null。
  int? blockOffsetOf(Text node, int sourceOffset) {
    final segment = _byNode[node];
    if (segment == null) return null;
    final clamped = sourceOffset.clamp(0, segment.rawLength);
    final raw = removeInsertedHyphens(
      node.text.substring(0, clamped),
      segment.displayBreaks.where((i) => i < clamped).toList(),
    );
    var emitted = collapseWhitespace(raw).length;
    if (segment.absorbedLeading && emitted > 0) emitted -= 1;
    emitted -= segment.hiddenLeading;
    if (emitted < 0) emitted = 0;
    if (emitted > segment.emittedLength) emitted = segment.emittedLength;
    return segment.blockOffset + emitted;
  }

  @override
  String toString() => 'DomTextMap(${segments.length}个片段)';
}

/// 逐块累积对照表；块的产出顺序就是正文顺序。
class DomTextMapBuilder {
  final List<DomTextSegment> _segments = [];
  final Map<Text, DomTextSegment> _byNode = {};
  final Map<String, List<DomTextSegment>> _byBlock = {};

  /// 记录一块的来源。
  ///
  /// 按正文 run 的边界折叠、裁剪，再累计块偏移，保留旧书正文口径。
  void addBlock(String blockId, String blockText, List<SourcePiece> pieces) {
    final joined = StringBuffer();
    var from = 0;
    while (from < pieces.length) {
      var to = from + 1;
      while (to < pieces.length &&
          pieces[to].runIndex == pieces[from].runIndex) {
        to++;
      }
      joined.write(_addRun(blockId, joined.length, pieces.sublist(from, to)));
      from = to;
    }
    assert(
      joined.toString() == blockText,
      '对照表与块文本口径不一致：$joined != $blockText',
    );
  }

  String _addRun(String blockId, int blockStart, List<SourcePiece> pieces) {
    final buffer = StringBuffer();
    final starts = <int>[];
    final texts = <String>[];
    final absorbed = <bool>[];
    var previousEndsWithSpace = false;

    for (final piece in pieces) {
      var text = collapseWhitespace(piece.raw);
      var isAbsorbed = false;
      // 上一片段末尾已是空格、本片段又以空格开头：合并成一个（与块构建的去重一致）
      if (previousEndsWithSpace && text.startsWith(' ')) {
        text = text.substring(1);
        isAbsorbed = true;
      }
      starts.add(buffer.length);
      texts.add(text);
      absorbed.add(isAbsorbed);
      buffer.write(text);
      previousEndsWithSpace = text.isNotEmpty
          ? text.endsWith(' ')
          : previousEndsWithSpace;
    }

    final joined = buffer.toString();
    final runText = joined.trim();
    final leading = joined.length - joined.trimLeft().length;
    final limit = leading + runText.length;

    for (var i = 0; i < pieces.length; i++) {
      final node = pieces[i].node;
      final text = texts[i];
      if (node == null || text.isEmpty) continue;
      final start = starts[i];
      final from = start < leading ? leading : start;
      final to = start + text.length > limit ? limit : start + text.length;
      if (to <= from) continue; // 整段落在被裁掉的首尾空白里
      final segment = DomTextSegment(
        node: node,
        blockId: blockId,
        blockOffset: blockStart + from - leading,
        hiddenLeading: from - start,
        emittedLength: to - from,
        absorbedLeading: absorbed[i],
        rawLength: node.text.length,
        displayBreaks: pieces[i].displayBreaks,
      );
      _segments.add(segment);
      _byNode[node] = segment;
      _byBlock.putIfAbsent(blockId, () => []).add(segment);
    }
    return runText;
  }

  DomTextMap build() => DomTextMap._(
    List.unmodifiable(_segments),
    Map.unmodifiable(_byNode),
    Map.unmodifiable(_byBlock),
  );
}
