import 'package:flutter/material.dart';

import 'gt_button.dart';

/// 保留现有列表行布局，整行点击和按压缩放使用 Forui。
/// 内部 ListTile 不再提供点击事件，避免两套手势同时响应。
class GtListButton extends StatelessWidget {
  const GtListButton({
    super.key,
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.trailing,
    this.leading,
    this.selected = false,
    this.contentPadding,
    this.minTileHeight,
  });
  final Widget title;
  final Widget? subtitle, trailing, leading;
  final VoidCallback? onPressed;
  final bool selected;
  final EdgeInsetsGeometry? contentPadding;
  final double? minTileHeight;

  @override
  Widget build(BuildContext context) => GtButton.raw(
    selected: selected,
    onPressed: onPressed,
    child: ListTile(
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      leading: leading,
      selected: selected,
      contentPadding: contentPadding,
      minTileHeight: minTileHeight,
    ),
  );
}
