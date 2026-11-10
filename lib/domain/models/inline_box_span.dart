/// 只包住一段文字的书内盒子。范围使用原正文 UTF-16 下标，不增加占位文字。
class InlineBoxSpan {
  const InlineBoxSpan({
    required this.start,
    required this.end,
    required this.box,
    required this.id,
    this.styleId,
    this.scale = 1,
    this.first = true,
    this.last = true,
  });

  final int start, end, id;
  final int? styleId;

  /// 与 ContentBlock.box 相同的数组，长度单位为 0.01em。
  final List<int> box;

  /// 盒子所属元素的字号倍数；内部加粗等子元素不能改变它的内边距。
  final double scale;

  /// 滚动长段分批测量时，人工切口不能重复添加左右内边距。
  final bool first, last;

  Map<String, Object?> toJson() => {
    's': start,
    'e': end,
    'id': id,
    if (styleId != null) 'sid': styleId,
    'box': box,
    'scale': scale,
    if (!first) 'first': false,
    if (!last) 'last': false,
  };

  factory InlineBoxSpan.fromJson(Map<String, Object?> json) => InlineBoxSpan(
    start: (json['s'] as num).toInt(),
    end: (json['e'] as num).toInt(),
    id: (json['id'] as num).toInt(),
    styleId: (json['sid'] as num?)?.toInt(),
    box: [for (final n in json['box'] as List) (n as num).toInt()],
    scale: (json['scale'] as num).toDouble(),
    first: json['first'] != false,
    last: json['last'] != false,
  );
}
