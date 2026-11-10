/// SVG 作为一个完整公式对象参与排版，原文范围仍保持不变。
class FormulaGeometry {
  const FormulaGeometry({required this.end, required this.baseline});
  final int end;
  final double baseline;
  FormulaGeometry shifted(int offset, {double scale = 1}) =>
      FormulaGeometry(end: end + offset, baseline: baseline * scale);
  Map<String, Object?> toJson() => {'end': end, 'baseline': baseline};
  factory FormulaGeometry.fromJson(Map j) => FormulaGeometry(
    end: (j['end'] as num).toInt(),
    baseline: (j['baseline'] as num).toDouble(),
  );
}

/// 引擎返回的固有尺寸以 em 表示，测量时再按真实字号和可用宽度换算。
class RenderedFormula {
  const RenderedFormula({
    required this.resource,
    required this.width,
    required this.height,
    required this.baseline,
  });
  final String resource;
  final double width, height, baseline;
}
