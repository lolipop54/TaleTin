import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'app_theme.dart';
import 'gt_tokens.dart';

/// Forui 复用当前区域的颜色和字体，阅读主题切换后同步更新菜单及按钮。
class GtForuiTheme extends StatelessWidget {
  const GtForuiTheme({super.key, required this.child});
  final Widget child;
  static final _themes = <(Brightness, String?, GtColors), FThemeData>{};

  static FThemeData _create(GtColors c, Brightness brightness, String? family) {
    final base = brightness == Brightness.dark
        ? FTheme.neutral.dark.touch
        : FTheme.neutral.light.touch;
    final colors = base.colors.copyWith(
      background: c.canvas,
      foreground: c.textPrimary,
      primary: c.actionPrimary,
      primaryForeground: c.onPrimary,
      secondary: c.subtle,
      secondaryForeground: c.textPrimary,
      muted: c.subtle,
      mutedForeground: c.textSecondary,
      card: c.surface,
      border: c.borderSubtle,
      barrier: c.scrim,
      destructive: c.danger,
      error: c.danger,
    );
    final typeface = FTypeface(
      fontFamily: family ?? 'sans-serif',
      sm: GtText.body(c.textPrimary, family: family),
      md: GtText.body(c.textPrimary, family: family),
    );
    final typography = FTypography(display: typeface, body: typeface);
    // 从项目颜色生成样式，同时关闭 Forui 组件内部按钮的按压缩放。
    final style =
        FStyle.inherit(
          colors: colors,
          typography: typography,
          touch: true,
        ).copyWith(
          tappableStyle: const FTappableStyleDelta.delta(
            motion: FTappableMotion.none,
          ),
        );
    return FThemeData(
      colors: colors,
      touch: true,
      typography: typography,
      style: style,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = (
      theme.brightness,
      theme.textTheme.bodyMedium?.fontFamily,
      context.gtColors,
    );
    // 应用主题过渡可能产生临时颜色，限制缓存数量，避免不断积累。
    if (!_themes.containsKey(key) && _themes.length >= 16) {
      _themes.remove(_themes.keys.first);
    }
    return FTheme(
      data: _themes.putIfAbsent(key, () => _create(key.$3, key.$1, key.$2)),
      // Material 已负责主题过渡，不给 Forui 再加一段错开的颜色动画。
      motion: const FThemeMotion(duration: Duration.zero),
      child: FTooltipGroup(child: child),
    );
  }
}
