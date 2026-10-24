/// 导入字体使用内容编号；显示名称和手机原路径不参与排版资源寻址。
class ImportedFontFace {
  const ImportedFontFace({
    required this.digest,
    required this.familyName,
    required this.minWeight,
    required this.maxWeight,
    required this.italic,
  });
  final String digest, familyName;
  final int minWeight, maxWeight;
  final bool italic;
  String get resource => 'gt-import-face-$digest';
  String get fileName => '$digest.ttf';
  String get style => italic ? 'italic' : 'normal';
  Map<String, Object> toJson() => {
    'digest': digest,
    'familyName': familyName,
    'minWeight': minWeight,
    'maxWeight': maxWeight,
    'italic': italic,
  };
  factory ImportedFontFace.fromJson(Map<String, dynamic> value) {
    final digest = value['digest'] as String;
    final name = value['familyName'] as String;
    final min = value['minWeight'] as int, max = value['maxWeight'] as int;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        name.isEmpty ||
        min < 1 ||
        max > 1000 ||
        min > max) {
      throw const FormatException('导入字体信息无效');
    }
    return ImportedFontFace(
      digest: digest,
      familyName: name,
      minWeight: min,
      maxWeight: max,
      italic: value['italic'] as bool,
    );
  }
}

class ImportedFontFamily {
  ImportedFontFamily({
    required this.id,
    required this.name,
    required List<ImportedFontFace> faces,
  }) : faces = List.unmodifiable(faces);
  final String id, name;
  final List<ImportedFontFace> faces;
  String get fingerprint => faces.map((f) => f.digest).join(':');
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'faces': faces.map((f) => f.toJson()).toList(),
  };
  factory ImportedFontFamily.fromJson(Map<String, dynamic> value) {
    final id = value['id'] as String;
    if (!RegExp(r'^gt-import-[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('导入字体编号无效');
    }
    final faces = (value['faces'] as List)
        .map((v) => ImportedFontFace.fromJson(v as Map<String, dynamic>))
        .toList();
    if (faces.isEmpty) throw const FormatException('导入字体缺少字形文件');
    return ImportedFontFamily(
      id: id,
      name: value['name'] as String,
      faces: faces,
    );
  }
}
