import 'package:flutter/material.dart';

import 'gt_button.dart';

/// 标题栏布局沿用 Material；自动返回/关闭入口也使用项目 Forui 按钮。
class GtAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GtAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.centerTitle,
    this.leadingWidth,
    this.bottom,
    this.surfaceTintColor,
    this.scrolledUnderElevation,
  });
  final Widget? title, leading;
  final List<Widget>? actions;
  final Color? backgroundColor, foregroundColor;
  final double? elevation;
  final bool? centerTitle;
  final double? leadingWidth, scrolledUnderElevation;
  final PreferredSizeWidget? bottom;
  final Color? surfaceTintColor;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final close = route is PageRoute && route.fullscreenDialog;
    return AppBar(
      title: title,
      centerTitle: centerTitle,
      leadingWidth: leadingWidth,
      bottom: bottom,
      surfaceTintColor: surfaceTintColor,
      scrolledUnderElevation: scrolledUnderElevation,
      actions: actions,
      automaticallyImplyLeading: false,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      elevation: elevation,
      leading:
          leading ??
          (route?.impliesAppBarDismissal == true
              ? GtButton.icon(
                  tooltip: close
                      ? MaterialLocalizations.of(context).closeButtonTooltip
                      : MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.maybePop(context),
                  icon: IconTheme(
                    data: IconThemeData(
                      color:
                          foregroundColor ??
                          Theme.of(context).appBarTheme.foregroundColor,
                    ),
                    child: close
                        ? const Icon(Icons.close)
                        : const BackButtonIcon(),
                  ),
                )
              : null),
    );
  }
}
