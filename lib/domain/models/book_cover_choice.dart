/// 预设编号持久保存，调整展示顺序时不能改变已有编号。
enum BookCoverPreset {
  parchment('parchment', '牛皮纸'),
  martial('martial', '武功秘籍'),
  mountains('mountains', '远山'),
  stars('stars', '星河'),
  botanical('botanical', '青叶'),
  ocean('ocean', '潮汐'),
  geometry('geometry', '构成'),
  cloth('cloth', '布纹');

  const BookCoverPreset(this.code, this.label);
  final String code, label;
}

/// null 表示跟随格式默认值；空选择明确使用原书封面，不覆盖原图。
class BookCoverChoice {
  const BookCoverChoice({this.preset, this.imagePath});
  final BookCoverPreset? preset;
  final String? imagePath;

  Map<String, Object?> toJson() => {
    'preset': preset?.code,
    'imagePath': imagePath,
  };

  factory BookCoverChoice.fromJson(Map<String, dynamic> json) {
    final code = json['preset'];
    final path = json['imagePath'] as String?;
    // 备份是外部输入，只接受本功能生成的相对文件名，不能越出单书目录。
    if (path != null &&
        !RegExp(
          r'^(covers/|global-covers/(txt|epub|mobi|azw3|pdf)/)[a-zA-Z0-9-]+\.png$',
        ).hasMatch(path)) {
      throw const FormatException('自定义封面路径无效');
    }
    return BookCoverChoice(
      preset: BookCoverPreset.values.where((p) => p.code == code).firstOrNull,
      imagePath: path,
    );
  }
}
