/// 背景编号用于保存选择；自定义名称只按当前列表位置生成，删除不会改动编号。
class ReadingBackground {
  const ReadingBackground(this.id, this.label, {this.asset, this.path});
  final String id, label;
  final String? asset, path;
  bool get custom => path != null;
  static const limit = 9;
  static const solid = ReadingBackground('solid', '纯色');
  static const presets = [
    solid,
    ReadingBackground('newspaper', '旧报纸', asset: 'assets/pics/阅读背景/旧报纸.jpg'),
    ReadingBackground('parchment', '羊皮纸', asset: 'assets/pics/阅读背景/羊皮纸.jpg'),
    ReadingBackground('boat', '孤舟', asset: 'assets/pics/阅读背景/孤舟.jpg'),
    ReadingBackground('landscape', '山水', asset: 'assets/pics/阅读背景/山水.png'),
  ];
}
