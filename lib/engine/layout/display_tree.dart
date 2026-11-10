/// 只用于当前排版的显示树：把正文块挂到来源索引的容器链上。
///
/// 它不是持久模型，也不改正文块号。测量时按这条链从外到内扣内边距和边框，
/// 绘制时按同一顺序先画外层背景、再画内层；分页片段只携带链的引用。
library;

import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import '../styles/chapter_styler.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';
import 'display_role.dart';
import 'math_formula.dart';

part 'display_anonymous_flow.dart';

class DisplayTree {
  final formulas = <int, RenderedFormula>{};
  DisplayTree({
    required this.source,
    required this.chains,
    required this.blockIndexById,
    this.nodes = const [],
    this.authoritative = false,
    this.boundaries = const {},
    this.emptyAt = const {},
    this.textLengths = const {},
    this.flows = const {},
    this.inlineEmpty = const {},
    this.emptySpace = const {},
  });

  final DisplaySourceIndex? source;
  final List<DisplayNode> nodes;
  final bool authoritative;
  final Map<int, int> textLengths;
  final Map<int, List<DisplayNode>> flows;
  final Map<int, List<DisplayNode>> inlineEmpty;
  final Set<int> emptySpace;
  final Map<int, Set<int>> boundaries;
  final Map<int, List<DisplayNode>> emptyAt;

  /// 第 i 个正文块的容器链（外层→内层）。没有来源索引时为空。
  final List<List<DisplayContainer>> chains;

  /// 正文块 ID → 它在章内的顺序；测量器按 ID 找容器链。
  final Map<String, int> blockIndexById;

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

    final flows = <int, List<DisplayNode>>{};
    for (final node in nodes.where((n) => n.isTextContainer && !hidden(n))) {
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
    final chains = <List<DisplayContainer>>[];
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
        if (element.tag == 'body' || element.tag == 'html') continue;
        if (!nodes[element.id].isBlock || element.styleId == null) continue;
        chain.add(
          DisplayContainer(
            elementId: element.id,
            styleId: element.styleId!,
            first: element.firstBlock == index,
            last: element.lastBlock == index,
            role: element.role,
            tag: element.tag,
          ),
        );
      }
      chains.add(chain);
    }
    _groupAnonymousFlow(nodes);
    final boundaries = <int, Set<int>>{};
    final emptyAt = <int, List<DisplayNode>>{};
    final inlineEmpty = <int, List<DisplayNode>>{};
    for (final node in nodes) {
      if (hidden(node)) continue;
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
          node.element.id != 0 &&
          node.isBlock &&
          (node.element.role != 'divider' ||
              !source.blockOwners.contains(node.element.id)) &&
          node.element.firstBlock == null &&
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
      chains: chains,
      blockIndexById: indexById,
      nodes: nodes,
      authoritative:
          content.displaySourceJson?['computed'] == true ||
          content.displaySourceJson?['css'] != null,
      boundaries: boundaries,
      emptyAt: emptyAt,
      textLengths: {
        for (var i = 0; i < content.blocks.length; i++)
          i: content.blocks[i].runLength,
      },
      flows: flows,
      inlineEmpty: inlineEmpty,
      emptySpace: {
        for (final n in nodes)
          if (_hasEmptySpace(n, table)) n.element.id,
      },
    );
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

  bool _emptyEdge(DisplayElement e, {required bool first}) =>
      _edgeEmpties(e, first).isNotEmpty;

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
        if (e.id != 0 && nodes[e.id].isBlock)
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
    int sourceOffset = 0,
    int? sourceEnd,
  }) {
    if (blockIndex < 0 || blockIndex >= chains.length) return const [];
    final end = sourceEnd ?? textLengths[blockIndex] ?? 0;
    return [
      for (final c in chains[blockIndex])
        DisplayContainer(
          elementId: c.elementId,
          styleId: c.styleId,
          first:
              c.first &&
              sourceOffset == 0 &&
              !_emptyEdge(source!.elements[c.elementId], first: true),
          last:
              c.last &&
              end >= (textLengths[blockIndex] ?? 0) &&
              !_emptyEdge(source!.elements[c.elementId], first: false),
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
