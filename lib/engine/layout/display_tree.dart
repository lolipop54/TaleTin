/// 只用于当前排版的显示树：把正文块挂到来源索引的容器链上。
///
/// 从外到内测量边框和内边距，按同一顺序绘制背景。分页片段引用这条链，正文块号沿用持久模型。
library;

import '../../domain/models/book_document.dart';
import '../../domain/models/content_table.dart';
import '../../domain/models/display_source_index.dart';
import '../styles/chapter_styler.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';
import 'display_role.dart';
import 'math_formula.dart';
import 'gallery_layout.dart';

part 'display_anonymous_flow.dart';
part 'display_image_flow.dart';

class DisplayTree {
  final formulas = <int, RenderedFormula>{};
  DisplayTree({
    required this.source,
    required this.chains,
    required this.blockIndexById,
    this.nodes = const [],
    this.authoritative = false,
    this.boundaries = const {},
    this.leadingBreaks = const {},
    this.frameLabels = const {},
    this.blankLines = const {},
    this.pageBreaks = const {},
    this.clearBreaks = const {},
    this.softBreaks = const {},
    this.compactLists = const {},
    this.legends = const {},
    this.listItems = const {},
    this.emptyAt = const {},
    this.emptyGrids = const {},
    this.emptyGridBlocks = const {},
    this.textLengths = const {},
    this.flows = const {},
    this.inlineEmpty = const {},
    this.imageWrappers = const {},
    this.emptySpace = const {},
    this.hiddenBlocks = const {},
    this.hiddenElements = const {},
    this.hiddenText = const {},
    this.hiddenBreaks = const {},
    this.inlineLayoutCandidates = const {},
    this.galleryCaptions = const {},
    this.portraits = const {},
    this.openingArtwork,
    this.coverBlockId,
  });

  final DisplaySourceIndex? source;
  final List<DisplayNode> nodes;
  final bool authoritative;

  /// 原 DOM 中通向可见块级引用的祖先。宽度检查只经过这些路径。
  late final Set<int> hasQuoteBelow = _quoteAncestors();

  Set<int> _quoteAncestors() {
    final result = <int>{};
    for (final node in nodes.reversed) {
      final e = node.element;
      if (node.anonymous ||
          e.parent == null ||
          hiddenElements.contains(e.id) ||
          const {'ol', 'ul', 'dl'}.contains(e.tag)) {
        continue;
      }
      if ((node.isBlock && e.tag == 'blockquote') || result.contains(e.id)) {
        result.add(e.parent!);
      }
    }
    return result;
  }

  final Map<int, int> textLengths;
  final Map<int, List<DisplayNode>> flows;
  final Map<int, List<DisplayNode>> inlineEmpty;
  final Map<int, DisplayNode> imageWrappers;
  final Set<int> emptySpace;
  final Set<int> hiddenBlocks;
  final Set<int> hiddenElements;
  final Map<int, List<(int, int)>> hiddenText;
  final Map<int, Set<int>> hiddenBreaks;
  final Map<int, List<DisplayNode>> inlineLayoutCandidates;
  final Map<String, PortraitEntry> portraits;
  final ({String id, int edges})? openingArtwork;
  final String? coverBlockId;
  final Map<String, ContentBlock> galleryCaptions;
  final Map<int, Set<int>> boundaries;
  final Map<int, int> leadingBreaks;

  /// 边框首尾整段带装饰的角标。按原段识别，滚动分段也沿用同一结果。
  final Set<int> frameLabels;

  /// 块序号 → 第一个 br 的正文位置 → 后续各个额外占一行的 br。
  final Map<int, Map<int, List<DisplayElement>>> blankLines;
  final Map<String, Set<int>> pageBreaks;
  final Map<int, Map<int, ClearSpec>> clearBreaks;
  final Map<int, Set<int>> softBreaks;
  final Set<int> compactLists;
  final Map<int, DisplayNode> legends;
  final Map<int, List<ContentBlock>> listItems;
  final Map<int, List<DisplayNode>> emptyAt;
  final Map<int, ContentTable> emptyGrids;
  final Map<String, ContentBlock> emptyGridBlocks;

  /// 第 i 个正文块的容器链（外层→内层）。没有来源索引时为空。
  final List<List<DisplayContainer>> chains;

  /// 正文块 ID → 它在章内的顺序；测量器按 ID 找容器链。
  final Map<String, int> blockIndexById;

  /// 表题保留源块号。与单元格一起测量，避免按 DOM 顺序再排一次底部表题。
  late final captionBlockIds = <String>{
    if (authoritative)
      for (final node in nodes)
        if (node.element.role == 'caption' &&
            (node.parent?.element.table != null ||
                emptyGrids.containsKey(node.element.parent)))
          ...blocksOf(node),
  };
  late final _idsByIndex = {
    for (final entry in blockIndexById.entries) entry.value: entry.key,
  };
  String anchorBlockId(int anchor) => _idsByIndex.isEmpty
      ? ''
      : _idsByIndex[anchor.clamp(0, _idsByIndex.length - 1)]!;

  Iterable<String> blocksOf(DisplayNode node) sync* {
    final first = node.element.firstBlock, last = node.element.lastBlock;
    if (first == null || last == null) return;
    for (var i = first; i <= last; i++) {
      if (_idsByIndex[i] case final id?) yield id;
    }
  }

  static DisplayTree build(ChapterContent content) {
    final source = DisplaySourceIndex.fromJson(content.displaySourceJson);
    final indexById = <String, int>{
      for (var i = 0; i < content.blocks.length; i++) content.blocks[i].id: i,
    };
    if (source == null) {
      return DisplayTree(
        source: null,
        chains: List.generate(content.blocks.length, (_) => const []),
        blockIndexById: indexById,
      );
    }
    final table = ChapterStyler.layoutTableOf(content);
    final nodes = [
      for (final e in source.elements)
        // 块级／行内的判断只有一处（display_role.dart），和行内盒子、断行
        // 边界共用同一个答案，避免同一个 `<code>` 在两处得到不同结果。
        DisplayNode(element: e, display: displayOf(e, table[e.styleId ?? 0])),
    ];
    for (final node in nodes) {
      node.children.addAll([for (final id in node.element.children) nodes[id]]);
      for (final child in node.children) {
        child.parent = node;
      }
    }
    bool hidden(DisplayNode node) {
      DisplayNode? current = node;
      while (current != null) {
        if (current.display == DisplaySpec.none) return true;
        current = current.parent;
      }
      return false;
    }

    final hiddenElements = {
      for (final node in nodes)
        if (hidden(node)) node.element.id,
    };
    final hiddenBlocks = {
      for (final (index, _) in content.blocks.indexed)
        if (source.ownerOfBlock(index) case final owner?)
          if (hiddenElements.contains(owner.id)) index,
    };
    final hiddenText = <int, List<(int, int)>>{};
    final hiddenBreaks = <int, Set<int>>{};
    final visibleBreaks = <int, Set<int>>{};
    final inlineLayoutCandidates = <int, List<DisplayNode>>{};
    for (final node in nodes) {
      final element = node.element;
      final isHidden = hiddenElements.contains(element.id);
      final computed = table[element.styleId ?? 0];
      if (!isHidden &&
          isInlineDisplay(node.display) &&
          (computed.block.float == FloatSpec.left ||
              (node.display == DisplaySpec.inlineBlock &&
                  computed.size.hasDimensions))) {
        for (final block
            in element.ranges.map((range) => range.block).toSet()) {
          (inlineLayoutCandidates[block] ??= []).add(node);
        }
      }
      if (element.tag == 'br') {
        final breaks = isHidden ? hiddenBreaks : visibleBreaks;
        (breaks[element.anchor] ??= {}).add(element.anchorOffset);
      }
      if (!isHidden || hiddenElements.contains(element.parent)) continue;
      final ranges = <int, (int, int)>{};
      for (final range in element.ranges) {
        if (range.start == range.end) continue;
        final previous = ranges[range.block];
        ranges[range.block] = previous == null
            ? (range.start, range.end)
            : (
                previous.$1 < range.start ? previous.$1 : range.start,
                previous.$2 > range.end ? previous.$2 : range.end,
              );
      }
      for (final entry in ranges.entries) {
        (hiddenText[entry.key] ??= []).add(entry.value);
      }
    }
    for (final entry in hiddenBreaks.entries) {
      entry.value.removeAll(visibleBreaks[entry.key] ?? const {});
    }
    int? visibleEdge(DisplayElement element, {required bool first}) {
      final start = element.firstBlock, end = element.lastBlock;
      if (start == null || end == null) return null;
      var edge = first ? start : end;
      while (edge >= start && edge <= end && hiddenBlocks.contains(edge)) {
        edge += first ? 1 : -1;
      }
      return edge;
    }

    final flows = <int, List<DisplayNode>>{};
    for (final node in nodes.where(
      (n) => n.isTextContainer && !hiddenElements.contains(n.element.id),
    )) {
      for (final range in node.element.ranges) {
        final owner = source.ownerOfBlock(range.block);
        if (owner == null || owner.id == node.element.id) continue;
        var parent = node.element.parent;
        while (parent != null && parent != owner.id) {
          parent = source.element(parent)?.parent;
        }
        if (parent == owner.id) (flows[range.block] ??= []).add(node);
      }
    }
    final listItems = <int, List<ContentBlock>>{};
    final chains = <List<DisplayContainer>>[];
    final frameLabels = <int>{};
    for (var index = 0; index < content.blocks.length; index++) {
      final chain = <DisplayContainer>[];
      for (final element in source.chainOfBlock(index)) {
        // 块自己的元素样式已经由 block.styleId 表示（它自己的盒子由 block.box 画），
        // 这里只保留真正的祖先容器，避免同一个盒子画两遍。
        if (element.id == source.blockOwners[index] &&
            element.role != 'block' &&
            element.role != 'list' &&
            !flows.containsKey(index)) {
          continue;
        }
        // 页面边距只由阅读器设置；html/body 的 padding 不能把整页正文挤小。
        if (element.tag == 'html' ||
            element.tag == 'body' &&
                content.displaySourceJson?['bodyMargin'] != true) {
          continue;
        }
        if (!nodes[element.id].isBlock || element.styleId == null) continue;
        chain.add(
          DisplayContainer(
            elementId: element.id,
            styleId: element.styleId!,
            first: visibleEdge(element, first: true) == index,
            last: visibleEdge(element, first: false) == index,
            role: element.role,
            tag: element.tag,
          ),
        );
      }
      final item = content.blocks[index];
      if (item.inlineBoxes.isNotEmpty &&
          table[item.styleId ?? 0].text.lineHeight != null &&
          chain.any((c) {
            final border = table[c.styleId].box.border;
            return (c.first && _paintedSide(border?.top)) ||
                (c.last && _paintedSide(border?.bottom));
          }) &&
          _onlyDecoratedText(item, table, hiddenElements, hiddenText[index])) {
        frameLabels.add(index);
      }
      if (item.kind == BlockKind.listItem && !hiddenBlocks.contains(index)) {
        final list = chain.reversed.where((c) => c.role == 'list').firstOrNull;
        if (list != null) (listItems[list.elementId] ??= []).add(item);
      }
      chains.add(chain);
    }
    final imageWrappers = _imageOnlyWrappers(source, nodes, table, hiddenElements);
    final imageBlocks = imageWrappers.values.toSet();
    _groupAnonymousFlow(nodes);
    final boundaries = <int, Set<int>>{};
    final leadingBreaks = <int, int>{};
    final blankLines = <int, Map<int, List<DisplayElement>>>{};
    DisplayElement? previousBreak;
    var firstBreakOffset = 0;
    final pageBreaks = <String, Set<int>>{};
    final softBreaks = <int, Set<int>>{};
    final legends = <int, DisplayNode>{};
    final clearBreaks = <int, Map<int, ClearSpec>>{};
    void pageBreak(int index, int offset) {
      if (index >= content.blocks.length) return;
      if (offset > 0 && offset >= content.blocks[index].runLength) {
        index++;
        offset = 0;
      }
      while (hiddenBlocks.contains(index)) {
        index++;
        offset = 0;
      }
      if (index >= content.blocks.length) return;
      (pageBreaks[content.blocks[index].id] ??= {}).add(offset);
      if (offset > 0) (boundaries[index] ??= {}).add(offset);
    }

    final emptyAt = <int, List<DisplayNode>>{};
    final emptyGrids = {
      for (final e
          in (content.displaySourceJson?['emptyGrids'] as Map? ?? const {})
              .entries)
        int.parse(e.key as String): ContentTable.fromJson(
          (e.value as Map).cast<String, dynamic>(),
        ),
    };
    final inlineEmpty = <int, List<DisplayNode>>{};
    for (final node in nodes) {
      if (hiddenElements.contains(node.element.id)) continue;
      final e = node.element;
      // 图片和公式可以不占正文字符，但仍隔开两边的换行。
      if (e.role == 'image' || e.math != null) previousBreak = null;
      final computed = table[e.styleId ?? 0];
      final style = computed.block;
      if (e.tag == 'legend' &&
          node.parent?.element.tag == 'fieldset' &&
          node.parent!.children.firstWhere((n) => n.element.tag == 'legend') ==
              node) {
        for (final r in e.ranges) {
          legends.putIfAbsent(r.block, () => node);
        }
      }
      if (e.tag == 'wbr') (softBreaks[e.anchor] ??= {}).add(e.anchorOffset);
      // 相邻的 nowrap 元素可能合并为同一个文字 run。保留每组的起点，
      // 这样两组放不下一行时仍可整组换行，组内嵌套的粗体等继续跟随原组。
      if (computed.text.whiteSpace == WhiteSpaceSpec.nowrap &&
          isInlineDisplay(node.display) &&
          table[node.parent?.element.styleId ?? 0].text.whiteSpace !=
              WhiteSpaceSpec.nowrap &&
          e.ranges.isNotEmpty) {
        final start = e.ranges.first;
        (softBreaks[start.block] ??= {}).add(start.start);
      }
      if (style.breakBefore == 'page' || style.breakBefore == 'always') {
        if (e.firstBlock == null || e.tag == 'mbp:pagebreak') {
          pageBreak(e.anchor, e.anchorOffset);
        } else {
          pageBreak(e.firstBlock!, 0);
        }
      }
      if (style.breakAfter == 'page' || style.breakAfter == 'always') {
        if (e.lastBlock != null) {
          pageBreak(e.lastBlock! + 1, 0);
        } else {
          pageBreak(e.anchor, e.anchorOffset);
        }
      }
      if (e.tag == 'br' &&
          style.clear != null &&
          style.clear != ClearSpec.none) {
        (clearBreaks[e.anchor] ??= {})[e.anchorOffset] = style.clear!;
      }
      // 多个 br 可能在旧正文裁剪中没有留下换行字符，来源索引仍保存准确
      // 位置。只恢复显示边界，不改正文长度；已有换行由测量器去重。
      if (node.element.tag == 'br') {
        final owner = source.ownerOfBlock(node.element.anchor);
        var parent = node.element.parent;
        while (parent != null && parent != owner?.id) {
          parent = source.element(parent)?.parent;
        }
        // 空白兄弟段落中的 br 也可能指向下一块的 0 偏移；它并不属于
        // 下一段，不能用这个临时锚点取消下一段首行缩进。
        if (owner != null && parent == owner.id) {
          if (e.anchorOffset == 0) {
            leadingBreaks.update(
              node.element.anchor,
              (n) => n + 1,
              ifAbsent: () => 1,
            );
          } else {
            final prev = previousBreak;
            // 旧正文只给连续空白保留一个位置。第二个 br 可能与第一个同位，
            // 也可能紧跟第一个 br 自己占用的那个字符。
            if (prev != null &&
                prev.anchor == e.anchor &&
                (prev.anchorOffset == e.anchorOffset ||
                    (prev.anchorOffset + 1 == e.anchorOffset &&
                        prev.ranges.any(
                          (r) => r.block == e.anchor && r.end == e.anchorOffset,
                        )))) {
              ((blankLines[e.anchor] ??= {})[firstBreakOffset] ??= []).add(e);
            } else {
              firstBreakOffset = e.anchorOffset;
            }
          }
          previousBreak = e;
          (boundaries[node.element.anchor] ??= {}).add(
            node.element.anchorOffset,
          );
        }
      }
      if (!node.anonymous && node.isBlock && !node.element.isContainer) {
        for (final range in node.element.ranges) {
          (boundaries[range.block] ??= {}).addAll([range.start, range.end]);
        }
      }
      var tableParent = node.parent;
      var insideTable = false;
      while (tableParent != null) {
        if (tableParent.element.role == 'table') {
          insideTable = true;
          break;
        }
        tableParent = tableParent.parent;
      }
      // `<hr>` 自己已经输出一个 divider 块（线型、框和 29px 占位都在那块里）。
      // 它没有文字，`firstBlock` 仍是 null，如果这里再当成空元素补一次装饰，
      // 同一根分隔线会被画两遍，还会多出一份上下外边距。其他只靠盒子占位的
      // 空容器仍按空元素处理。
      if (!insideTable &&
          !imageBlocks.contains(node) &&
          node.element.role != 'root' &&
          node.element.id != 0 &&
          node.isBlock &&
          (node.element.role != 'divider' ||
              !source.blockOwners.contains(node.element.id)) &&
          (node.element.firstBlock == null ||
              emptyGrids.containsKey(node.element.id)) &&
          (node.element.parent == null ||
              node.element.parent == 0 ||
              source.element(node.element.parent!)!.firstBlock != null)) {
        final target = node.element.anchorOffset > 0 ? inlineEmpty : emptyAt;
        (target[node.element.anchor] ??= []).add(node);
      }
    }
    for (final index in inlineEmpty.keys) {
      final owner = source.ownerOfBlock(index);
      if (owner?.styleId != null &&
          !chains[index].any((c) => c.elementId == owner!.id)) {
        chains[index].add(
          DisplayContainer(
            elementId: owner!.id,
            styleId: owner.styleId!,
            first: owner.firstBlock == index,
            last: owner.lastBlock == index,
            role: owner.role,
            tag: owner.tag,
          ),
        );
      }
    }
    return DisplayTree(
      source: source,
      frameLabels: frameLabels,
      coverBlockId: standaloneCover(content, hiddenBlocks),
      leadingBreaks: leadingBreaks,
      blankLines: blankLines,
      pageBreaks: pageBreaks,
      clearBreaks: clearBreaks,
      softBreaks: softBreaks,
      legends: legends,
      compactLists:
          (content.displaySourceJson?['compactLists'] as List? ?? const [])
              .cast<int>()
              .toSet(),
      listItems: listItems,
      portraits: portraitEntries(source, content, hiddenBlocks, table),
      openingArtwork: chapterOpeningArtwork(
        source,
        content,
        hiddenBlocks,
        table,
      ),
      galleryCaptions: figureCaptions(source, content, hiddenBlocks, table),
      hiddenBlocks: hiddenBlocks,
      hiddenElements: hiddenElements,
      hiddenText: hiddenText,
      hiddenBreaks: hiddenBreaks,
      inlineLayoutCandidates: inlineLayoutCandidates,
      chains: chains,
      blockIndexById: indexById,
      nodes: nodes,
      authoritative:
          content.displaySourceJson?['computed'] == true ||
          content.displaySourceJson?['css'] != null,
      boundaries: boundaries,
      emptyAt: emptyAt,
      emptyGrids: emptyGrids,
      emptyGridBlocks: {
        for (final id in emptyGrids.keys)
          for (final cap in nodes[id].children.where(
            (n) => n.element.role == 'caption',
          ))
            if (cap.element.firstBlock != null)
              for (
                var i = cap.element.firstBlock!;
                i <= cap.element.lastBlock!;
                i++
              )
                content.blocks[i].id: content.blocks[i],
      },
      textLengths: {
        for (var i = 0; i < content.blocks.length; i++)
          i: content.blocks[i].runLength,
      },
      flows: flows,
      inlineEmpty: inlineEmpty,
      imageWrappers: imageWrappers,
      emptySpace: {
        for (final n in nodes)
          if (_hasEmptySpace(n, table)) n.element.id,
      },
    );
  }

  /// 目录指向隐藏锚点时，落到同章紧随其后的可见内容；章尾锚点则往前找。
  int? visibleIndexForHidden(String blockId) {
    final index = blockIndexById[blockId];
    if (index == null || !hiddenBlocks.contains(index)) return null;
    for (var i = index + 1; i < chains.length; i++) {
      if (!hiddenBlocks.contains(i)) return i;
    }
    for (var i = index - 1; i >= 0; i--) {
      if (!hiddenBlocks.contains(i)) return i;
    }
    return null;
  }

  /// 块内的显示边界只约束断行，不插入换行文字或改变 UTF-16 偏移。
  Set<int> blockBoundaries(int blockIndex) =>
      boundaries[blockIndex] ?? const {};
  List<DisplayNode> emptyBefore(int blockIndex) =>
      emptyAt[blockIndex] ?? const [];

  bool ownsContainer(int index) {
    final owner = source?.ownerOfBlock(index);
    return owner != null && chains[index].any((c) => c.elementId == owner.id);
  }

  bool _inside(DisplayElement child, int ancestor) {
    int? id = child.id;
    while (id != null) {
      if (id == ancestor) return true;
      id = source?.element(id)?.parent;
    }
    return false;
  }

  Iterable<DisplayNode> _edgeEmpties(DisplayElement e, bool first) {
    final index = first ? e.firstBlock : e.lastBlock;
    if (index == null) return const [];
    return emptyAt.values
        .expand((v) => v)
        .where(
          (n) =>
              emptySpace.contains(n.element.id) &&
              _inside(n.element, e.id) &&
              (first
                  ? n.element.anchor < index ||
                        (n.element.anchor == index &&
                            n.element.anchorOffset == 0)
                  : n.element.anchor > index),
        );
  }

  bool _emptyEdge(DisplayElement e, bool first, List<DisplayNode> merged) =>
      _edgeEmpties(e, first).any((node) => !merged.contains(node));

  static bool _hasEmptySpace(DisplayNode node, StyleTable table) {
    if (node.element.firstBlock != null) return false;
    final style = table[node.element.styleId ?? 0];
    bool positive(Length? value) =>
        value != null &&
        !value.isAuto &&
        value.resolve(
              const LengthContext(fontSize: 1, rootFontSize: 1, reference: 1),
            ) >
            0;
    final box = style.box;
    return [
          style.size.height,
          style.size.minHeight,
          box.padding?.top,
          box.padding?.bottom,
        ].any(positive) ||
        [
          box.border?.top,
          box.border?.bottom,
        ].any((s) => s?.isVisible == true && positive(s?.width)) ||
        node.children.any((n) => _hasEmptySpace(n, table));
  }

  bool _emptyIsEdge(DisplayNode node, DisplayElement container, bool first) {
    if (container.firstBlock == null) return true;
    final candidates = _edgeEmpties(container, first).toList()
      ..sort((a, b) {
        final block = a.element.anchor.compareTo(b.element.anchor);
        if (block != 0) return block;
        final offset = a.element.anchorOffset.compareTo(b.element.anchorOffset);
        return offset != 0 ? offset : a.element.id.compareTo(b.element.id);
      });
    return candidates.isNotEmpty &&
        (first ? candidates.first : candidates.last) == node;
  }

  /// 空节点也从真实祖先获得同一条约束链；它自身是链的最后一层。
  List<DisplayContainer> chainOfEmpty(DisplayNode node) {
    final ancestors = <DisplayElement>[];
    DisplayElement? e = node.element;
    while (e != null) {
      ancestors.add(e);
      e = e.parent == null ? null : source?.element(e.parent!);
    }
    return [
      for (final e in ancestors.reversed)
        if (e.id != 0 && e.role != 'root' && nodes[e.id].isBlock)
          DisplayContainer(
            elementId: e.id,
            styleId: e.styleId ?? 0,
            role: e.role,
            tag: e.tag,
            first: _emptyIsEdge(node, e, true),
            last: _emptyIsEdge(node, e, false),
          ),
    ];
  }

  List<DisplayContainer> chainOf(
    int blockIndex, {
    Set<int> outOfFlow = const {},
    List<DisplayNode> merged = const [],
    int sourceOffset = 0,
    int? sourceEnd,
  }) {
    if (blockIndex < 0 || blockIndex >= chains.length) return const [];
    final end = sourceEnd ?? textLengths[blockIndex] ?? 0;
    // 定位图片不占父框的内边距，把首尾标记交给实际参与排列的正文。
    bool edge(DisplayContainer c, bool first) {
      if (first ? c.first : c.last) return true;
      if (outOfFlow.isEmpty) return false;
      final e = source!.elements[c.elementId];
      final outer = first ? e.firstBlock : e.lastBlock;
      if (outer == null) return false;
      var at = outer;
      while (at != blockIndex &&
          (outOfFlow.contains(at) || hiddenBlocks.contains(at))) {
        at += first ? 1 : -1;
      }
      return at == blockIndex;
    }

    return [
      for (final c in chains[blockIndex])
        DisplayContainer(
          elementId: c.elementId,
          styleId: c.styleId,
          first:
              edge(c, true) &&
              sourceOffset == 0 &&
              !_emptyEdge(source!.elements[c.elementId], true, merged),
          last:
              edge(c, false) &&
              end >= (textLengths[blockIndex] ?? 0) &&
              !_emptyEdge(source!.elements[c.elementId], false, merged),
          role: c.role,
          tag: c.tag,
        ),
      for (final node in (flows[blockIndex] ?? const <DisplayNode>[]).toSet())
        for (final r in node.element.ranges)
          if (r.block == blockIndex &&
              r.start <= sourceOffset &&
              r.end >= end &&
              node.element.styleId != null)
            DisplayContainer(
              elementId: node.element.id,
              styleId: node.element.styleId!,
              first:
                  node.element.firstBlock == blockIndex &&
                  r.start == sourceOffset,
              last: node.element.lastBlock == blockIndex && r.end == end,
              role: node.element.role,
              tag: node.element.tag,
            ),
    ];
  }
}

bool _paintedSide(BorderSideSpec? side) =>
    side != null &&
    side.isVisible &&
    (side.color?.argb ?? 0xff000000) >>> 24 != 0;

bool _onlyDecoratedText(
  ContentBlock block,
  StyleTable table,
  Set<int> hidden,
  List<(int, int)>? hiddenText,
) {
  final ranges = <(int, int)>[];
  for (final span in block.inlineBoxes) {
    if (hidden.contains(span.id) || span.start == span.end) continue;
    final box = table[span.styleId ?? 0].box;
    final border = box.border;
    if ((box.background?.color?.argb ?? 0) >>> 24 != 0 ||
        box.background?.imageUrl != null ||
        (border != null &&
            [
              border.top,
              border.right,
              border.bottom,
              border.left,
            ].any(_paintedSide))) {
      ranges.add((span.start, span.end));
    }
  }
  if (ranges.isEmpty) return false;
  // 嵌套和相邻的装饰可以合成一个角标；空白和隐藏文字不打断它。
  // 只要还有可见正文未被覆盖，整段继续使用阅读器行距。
  if (hiddenText != null) ranges.addAll(hiddenText);
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  String? text;
  bool hasText(int from, int to) =>
      from < to &&
      (text ??= block.runs.map((r) => r.text).join())
          .substring(from, to)
          .trim()
          .isNotEmpty;
  var end = 0;
  for (final range in ranges) {
    if (hasText(end, range.$1)) return false;
    if (range.$2 > end) end = range.$2;
  }
  return !hasText(end, block.runLength);
}

class DisplayContainer {
  const DisplayContainer({
    required this.elementId,
    required this.styleId,
    required this.first,
    required this.last,
    required this.role,
    required this.tag,
  });

  final int elementId;
  final int styleId;

  /// 这个块是不是该容器在本章的第一块／最后一块：只有首尾块计上下内边距和边框。
  final bool first;
  final bool last;
  final String role;
  final String tag;

  /// 保留真实标签：blockquote 与 div 的来源角色同为 block，不能靠角色辨别缩进。
  bool get isQuoteOrList =>
      const {'blockquote', 'ul', 'ol', 'dl'}.contains(tag);
}

/// 原元素关系与实际显示角色分别保存；正文范围不承担容器身份。
class DisplayNode {
  DisplayNode({
    required this.element,
    required this.display,
    this.anonymous = false,
  });
  final DisplayElement element;
  final DisplaySpec display;
  final bool anonymous;
  DisplayNode? parent;
  final List<DisplayNode> children = [];
  bool get isBlock => isBlockDisplay(display);

  /// 换行和媒体是行流里的事件，不是可拆分文字的容器。它们仍由同一
  /// 显示角色提供边界，不能把换行占位字符单独量成一个“文字段”。
  bool get isTextContainer =>
      isBlock &&
      element.tag != 'br' &&
      element.role != 'image' &&
      element.role != 'divider';
}
