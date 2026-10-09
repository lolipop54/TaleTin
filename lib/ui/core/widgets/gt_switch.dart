import 'package:flutter/material.dart';

/// 全应用共用的小号开关：只缩小外观，保留原生点击范围、拖动及无障碍语义。
class GtSwitch extends StatelessWidget {
  const GtSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.scale = 0.8,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// 默认沿用原外观；标题栏可进一步缩小显示，点击范围保持不变。
  final double scale;

  @override
  Widget build(BuildContext context) => Transform.scale(
    scale: scale,
    // 外观约 42×26，命中范围仍按原生开关的至少 48dp 高度计算。
    transformHitTests: false,
    child: Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
  );
}
