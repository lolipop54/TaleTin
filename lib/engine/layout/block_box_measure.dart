part of 'block_measure.dart';

extension _BlockBoxMeasurement on BlockMeasurer {
  LengthContext _lengthContext(ComputedStyle style, double reference) {
    return DisplayBoxLayout.context(style, options, reference);
  }

  BlockBox? _boxFromRaw(List<int>? raw, double fontSize) =>
      BlockBox.fromRaw(raw, fontSize);

  /// 阴影和盒子使用相同长度环境，不把 px 提前折为 em。
  List<Shadow>? _textShadowOf(ResolvedBlockStyle style) {
    final values = style.computed.text.shadow;
    if (values == null || values.isEmpty) return null;
    final context = _lengthContext(style.computed, options.contentWidth);
    double px(Length? value) =>
        value == null || value.isAuto ? 0 : value.resolve(context);
    return [
      for (final value in values)
        Shadow(
          offset: Offset(px(value.offsetX), px(value.offsetY)),
          blurRadius: math.max(0, px(value.blur)),
          color: Color(value.color?.argb ?? 0),
        ),
    ];
  }
}
