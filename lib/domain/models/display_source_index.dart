/// 显示来源索引（纯数据）：Rust 在原 DOM 还在时记录的元素父子、顺序、块范围。
///
/// 它不是新的持久正文，也不复制文字；块只按顺序引用。元素编号只在当前章源摘要和
/// 规则版本内有效，不能作为书签、笔记或听书坐标。
library;

class DisplaySourceIndex {
  DisplaySourceIndex({
    required this.elements,
    required this.blockOwners,
    required this.blockElements,
    this.codeLines = const {},
    this.spaces = const {},
    this.hasLinkSemantics = false,
  });

  static const int version = 1;

  final List<DisplayElement> elements;

  /// 第 i 个正文块由哪个元素产生（元素 id）。
  final List<int> blockOwners;

  /// 第 i 个正文块对应的最内层元素 id（当前与 blockOwners 同值，保留字段便于以后细分）。
  final List<int> blockElements;
  final Map<int, Map<int, int>> codeLines;
  final Map<int, Map<int, int>> spaces;
  final bool hasLinkSemantics;

  static DisplaySourceIndex? fromJson(Map<String, Object?>? json) {
    if (json == null || json['v'] != version) return null;
    final raw = json['elements'];
    if (raw is! List || raw.isEmpty) return null;
    final elements = <DisplayElement>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = item.cast<String, Object?>();
      elements.add(
        DisplayElement(
          id: (map['id'] as num?)?.toInt() ?? elements.length,
          parent: (map['p'] as num?)?.toInt(),
          nodeId: (map['n'] as num?)?.toInt() ?? 0,
          tag: map['tag'] as String? ?? '',
          isLink: map['link'] == true,
          listOrdinal: (map['listOrdinal'] as num?)?.toInt(),
          role: map['r'] as String? ?? 'block',
          firstBlock: (map['b'] as num?)?.toInt(),
          lastBlock: (map['e'] as num?)?.toInt(),
          children: [
            for (final child in (map['c'] as List? ?? const []))
              (child as num).toInt(),
          ],
          styleId: (map['s'] as num?)?.toInt(),
          table: (map['t'] as num?)?.toInt(),
          math: map['math'] as String?,
          anchor: (map['at'] as num?)?.toInt() ?? 0,
          anchorOffset: (map['off'] as num?)?.toInt() ?? 0,
          ranges: [
            for (final r in map['ranges'] as List? ?? const [])
              DisplayTextRange(
                (r[0] as num).toInt(),
                (r[1] as num).toInt(),
                (r[2] as num).toInt(),
              ),
          ],
        ),
      );
    }
    return DisplaySourceIndex(
      hasLinkSemantics: json['linkSemantics'] == true,
      codeLines: _codeLines(json['codeLines']),
      spaces: _codeLines(json['spaces']),
      elements: elements,
      blockOwners: [
        for (final value in (json['blocks'] as List? ?? const []))
          (value as num).toInt(),
      ],
      blockElements: [
        for (final value in (json['blockElements'] as List? ?? const []))
          (value as num).toInt(),
      ],
    );
  }

  static Map<int, Map<int, int>> _codeLines(Object? raw) {
    final result = <int, Map<int, int>>{};
    for (final line in raw as List? ?? const []) {
      final values = (line as List).cast<num>();
      (result[values[0].toInt()] ??= {})[values[1].toInt()] = values[2].toInt();
    }
    return result;
  }

  DisplayElement? element(int id) =>
      id >= 0 && id < elements.length ? elements[id] : null;

  /// 一个块从根到自己的元素链（外层→内层）。没有索引时返回空。
  List<DisplayElement> chainOfBlock(int blockIndex) {
    if (blockIndex < 0 || blockIndex >= blockOwners.length) return const [];
    var current = element(blockOwners[blockIndex]);
    final chain = <DisplayElement>[];
    final seen = <int>{};
    while (current != null && seen.add(current.id)) {
      chain.add(current);
      current = current.parent == null ? null : element(current.parent!);
    }
    return chain.reversed.toList(growable: false);
  }

  /// 块所属的最内层元素；没有索引时 null。
  DisplayElement? ownerOfBlock(int blockIndex) {
    if (blockIndex < 0 || blockIndex >= blockOwners.length) return null;
    return element(blockOwners[blockIndex]);
  }

  Map<String, Object?> toJson() => {
    'v': version,
    if (hasLinkSemantics) 'linkSemantics': true,
    'elements': [for (final element in elements) element.toJson()],
    'blocks': blockOwners,
    'blockElements': blockElements,
  };
}

class DisplayElement {
  const DisplayElement({
    required this.id,
    required this.parent,
    required this.nodeId,
    required this.tag,
    required this.role,
    required this.firstBlock,
    required this.lastBlock,
    required this.children,
    this.styleId,
    this.table,
    this.math,
    this.anchor = 0,
    this.anchorOffset = 0,
    this.ranges = const [],
    this.isLink = false,
    this.listOrdinal,
  });

  final int id;
  final int? parent;
  final int nodeId;
  final String tag;
  final bool isLink;
  final int? listOrdinal;
  final String role;
  final int? firstBlock;
  final int? lastBlock;
  final List<int> children;
  final int? styleId;
  final int? table;

  /// 原始 MathML 结构，只用于显示；原文与 UTF-16 范围仍由 ranges 表示。
  final String? math;
  final int anchor;
  final int anchorOffset;
  final List<DisplayTextRange> ranges;

  bool get isContainer =>
      role == 'root' ||
      role == 'block' ||
      role == 'paragraph' ||
      role == 'heading' ||
      role == 'list' ||
      role == 'listItem' ||
      role == 'code' ||
      role == 'caption' ||
      role == 'table' ||
      role == 'row' ||
      role == 'cell';

  Map<String, Object?> toJson() => {
    'id': id,
    'p': parent,
    'n': nodeId,
    'tag': tag,
    if (isLink) 'link': true,
    if (listOrdinal != null) 'listOrdinal': listOrdinal,
    'at': anchor,
    if (anchorOffset != 0) 'off': anchorOffset,
    'ranges': [
      for (final range in ranges) [range.block, range.start, range.end],
    ],
    'r': role,
    'b': firstBlock,
    'e': lastBlock,
    'c': children,
    if (styleId != null) 's': styleId,
    if (math != null) 'math': math,
    if (table != null) 't': table,
  };
}

/// 一个元素在既有正文中的连续 UTF-16 范围。
class DisplayTextRange {
  const DisplayTextRange(this.block, this.start, this.end);
  final int block, start, end;
}
