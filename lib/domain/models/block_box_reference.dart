/// 内层代码块所属的外层容器。只保存结构编号和样式编号，样式仍由章节表提供。
class BlockBoxReference {
  const BlockBoxReference({required this.id, required this.styleId});

  final int id;
  final int styleId;

  Map<String, Object?> toJson() => {'boxId': id, 'sid': styleId};

  static BlockBoxReference fromJson(Map<String, Object?> json) =>
      BlockBoxReference(
        id: (json['boxId'] as num).toInt(),
        styleId: (json['sid'] as num).toInt(),
      );
}
