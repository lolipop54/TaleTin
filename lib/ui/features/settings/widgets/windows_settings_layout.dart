import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/decorations.dart';
import 'settings_heading.dart';

enum SettingsCategory {
  appearance('外观'),
  reading('阅读'),
  data('数据'),
  about('关于');

  const SettingsCategory(this.label);
  final String label;
}

typedef SettingsEntriesBuilder = List<Widget> Function(
  BuildContext,
  SettingsCategory,
);

/// 导航铺满标题下方；首页按整个区域排卡片，子页在同一区域内靠左限宽。
class WindowsSettingsPane extends InheritedWidget {
  const WindowsSettingsPane._({required this.entries, required super.child});

  final SettingsEntriesBuilder entries;
  static double _singleColumnWidth(BuildContext context) =>
      GtSize.desktopTwoColumnMinWidth *
      MediaQuery.textScalerOf(context).scale(1);

  static double detailWidth(BuildContext context, double available) =>
      math.min(available, _singleColumnWidth(context));

  static bool contains(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WindowsSettingsPane>() != null;

  @override
  bool updateShouldNotify(WindowsSettingsPane oldWidget) =>
      oldWidget.entries != entries;
}

class WindowsSettingsLayout extends StatefulWidget {
  const WindowsSettingsLayout({super.key, required this.entries});

  final SettingsEntriesBuilder entries;

  @override
  State<WindowsSettingsLayout> createState() => _WindowsSettingsLayoutState();
}

class _WindowsSettingsLayoutState extends State<WindowsSettingsLayout> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final theme = Theme.of(context);
    final titleStyle = GtText.pageTitle(colors.textPrimary)
        .copyWith(fontSize: 22);
    final paneTheme = theme.copyWith(
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: colors.surface,
        centerTitle: false,
        titleTextStyle:
            theme.appBarTheme.titleTextStyle?.merge(titleStyle) ?? titleStyle,
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final edge = constraints.maxWidth >= GtSize.desktopTwoColumnMinWidth
            ? 32.0
            : 16.0;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: edge, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SettingsHeader(titleSize: 29),
              const SizedBox(height: 16),
              Expanded(
                child: Theme(
                  data: paneTheme,
                  child: WindowsSettingsPane._(
                    entries: widget.entries,
                    child: NavigatorPopHandler<void>(
                      enabled: TickerMode.valuesOf(context).enabled,
                      onPopWithResult: (_) =>
                          _navigator.currentState!.maybePop(),
                      child: Navigator(
                        key: _navigator,
                        onGenerateRoute: (settings) => MaterialPageRoute<void>(
                          settings: settings,
                          builder: (_) => const _SettingsHome(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsHome extends StatelessWidget {
  const _SettingsHome();

  static const _shadowDepth = 4.0;

  @override
  Widget build(BuildContext context) {
    final pane = context
        .dependOnInheritedWidgetOfExactType<WindowsSettingsPane>()!;
    final colors = context.gtColors;
    final shape = _paneShape(colors);
    final cardDecoration = BoxDecoration(
      borderRadius: shape.borderRadius,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark ? .24 : .05,
          ),
          offset: const Offset(0, _shadowDepth),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        final twoColumns =
            box.maxWidth >= WindowsSettingsPane._singleColumnWidth(context);
        final width = twoColumns ? (box.maxWidth - 20) / 2 : box.maxWidth;
        return SingleChildScrollView(
          // 给最后一张卡片的底影留出滚动范围。
          padding: const EdgeInsets.only(bottom: _shadowDepth),
          child: Wrap(
            spacing: 20,
            runSpacing: 20,
            children: [
              for (final category in SettingsCategory.values)
                Container(
                  width: width,
                  decoration: cardDecoration,
                  child: Material(
                    color: colors.surface,
                    shape: shape,
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            constraints: const BoxConstraints(
                              minHeight: kToolbarHeight,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            alignment: Alignment.centerLeft,
                            child: FoldCornerHeading(
                              category.label,
                              style: Theme.of(context)
                                  .appBarTheme
                                  .titleTextStyle,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                            child: Column(
                              children: pane.entries(context, category),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

RoundedRectangleBorder _paneShape(GtColors colors) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(12),
  side: BorderSide(color: colors.borderSubtle),
);

class WindowsSettingsDetail extends StatelessWidget {
  const WindowsSettingsDetail({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    // 淡入时整块背景接替首页，只有正文所在的部分绘制面板和边框。
    return ColoredBox(
      color: colors.canvas,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(
            WindowsSettingsPane.detailWidth(context, box.maxWidth),
            box.maxHeight,
          );
          // 图库和许可页也使用表单实际宽度来决定列数和分栏。
          return Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: Material(
                color: colors.surface,
                shape: _paneShape(colors),
                clipBehavior: Clip.antiAlias,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(size: size),
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
