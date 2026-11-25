import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/reading_theme.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/toc_presentation_provider.dart';
import 'reader_panel_motion.dart';
import 'reader_desktop_layout.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../settings/view_models/reading_backgrounds.dart';
import '../../settings/view_models/listening_preferences.dart';
import '../view_models/listening_panel_view_model.dart';

/// 一级与二级面板共用工具栏；二级面板禁用所属的一级入口。
class ReaderToolbar extends StatelessWidget {
  const ReaderToolbar({
    super.key,
    required this.theme,
    required this.onSelect,
    this.blocked,
    this.selected,
    this.showListening = true,
  });
  final ReadingTheme theme;
  final ValueChanged<ReaderPanel>? onSelect;
  final ReaderPanel? blocked;
  final ReaderPanel? selected;
  final bool showListening;
  @override
  Widget build(BuildContext context) {
    final items = [
      (ReaderPanel.contents, GtIcons.toc, '目录'),
      (
        ReaderPanel.brightness,
        GtIcons.brightness,
        readerUsesDesktopPanels ? '外观' : '亮度',
      ),
      if (showListening)
        (ReaderPanel.tts, GtIcons.headphones, '听书'),
      (ReaderPanel.auto, GtIcons.autoRead, '自动阅读'),
      (ReaderPanel.typography, GtIcons.settings, '设置'),
    ];
    if (readerUsesDesktopPanels) {
      final labels = MediaQuery.sizeOf(context).width >= 760;
      final colors = context.gtColors;
      final radius = BorderRadius.circular(7);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: colors.subtle,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (panel, icon, label) in items)
                GtButton.raw(
                  key: ValueKey('windows-reader-tool-${panel.name}'),
                  borderRadius: radius,
                  tooltip: label,
                  showTooltipOnWindows: !labels,
                  selected: selected == panel,
                  onPressed: onSelect == null || blocked == panel
                      ? null
                      : () => onSelect!(panel),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected == panel
                          ? colors.actionPrimary.withValues(alpha: .14)
                          : Colors.transparent,
                      borderRadius: radius,
                    ),
                    child: SizedBox(
                      height: 34,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: labels ? 10 : 8,
                        ),
                        child: Row(
                          children: [
                            GtIcon(icon, size: 18, color: theme.primary),
                            if (labels) ...[
                              const SizedBox(width: 6),
                              _DesktopToolbarLabel(
                                label,
                                style: TextStyle(
                                  inherit: false,
                                  color: theme.primary,
                                  fontFamily: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.fontFamily,
                                  fontWeight: selected == panel
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  fontSize: 13,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Container(
      color: theme.background,
      height: readerToolbarHeight,
      child: Column(
        children: [
          Container(height: 1, color: theme.secondary.withValues(alpha: .18)),
          Expanded(
            child: Row(
              children: [
                for (final (index, item) in items.indexed) ...[
                  if (index > 0)
                    Container(
                      width: 1,
                      height: 36,
                      color: theme.secondary.withValues(alpha: .18),
                    ),
                  Expanded(
                    child: GtButton.raw(
                      onPressed: onSelect == null || blocked == item.$1
                          ? null
                          : () => onSelect!(item.$1),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GtIcon(item.$2, size: 24, color: theme.primary),
                          const SizedBox(height: GtSpacing.s1),
                          Text(
                            item.$3,
                            style: GtText.caption(theme.primary).copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopToolbarLabel extends StatelessWidget {
  const _DesktopToolbarLabel(this.label, {required this.style});

  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    const heightBehavior = TextHeightBehavior(
      leadingDistribution: TextLeadingDistribution.even,
    );
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: direction,
      textScaler: scaler,
      textHeightBehavior: heightBehavior,
      locale: locale,
      maxLines: 1,
    )..layout();
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length),
    );
    // 中文系统字体的行框上下留白可能不同，居中时对齐文字范围与图标中心。
    final shift = boxes.isEmpty
        ? 0.0
        : (painter.height -
                  boxes.map((box) => box.top).reduce(math.min) -
                  boxes.map((box) => box.bottom).reduce(math.max)) /
              2;
    painter.dispose();
    return Transform.translate(
      offset: Offset(0, shift),
      child: Text(
        label,
        style: style,
        textDirection: direction,
        textScaler: scaler,
        textHeightBehavior: heightBehavior,
        locale: locale,
        maxLines: 1,
      ),
    );
  }
}

/// 数据全部就绪后才切换面板，等待期间保留原面板。
Future<void> prepareReaderPanel(
  BuildContext context,
  ProviderContainer container,
  String bookId,
  ReaderPanel panel,
) async {
  if (panel == ReaderPanel.contents) {
    // 子路由打开时，父页的订阅会暂停；准备期间另持订阅，保证查询流继续工作。
    final toc = container.listen(bookTocProvider(bookId), (_, _) {});
    final sections = container.listen(
      readerTxtSectionsProvider(bookId),
      (_, _) {},
    );
    final bookmarks = container.listen(bookmarksProvider(bookId), (_, _) {});
    final notes = container.listen(annotationsProvider(bookId), (_, _) {});
    try {
      await Future.wait([
        container.read(bookTocProvider(bookId).future),
        container.read(readerTxtSectionsProvider(bookId).future),
        container.read(bookmarksProvider(bookId).future),
        container.read(annotationsProvider(bookId).future),
      ]);
    } finally {
      toc.close();
      sections.close();
      bookmarks.close();
      notes.close();
    }
  } else if (panel == ReaderPanel.tts) {
    // 单独打开阅读器时首页的订阅可能已暂停，准备期间保持这次读取有效。
    final preferences = container.listen(listeningPreferencesProvider, (_, _) {});
    try {
      await Future.wait([
        container.read(listeningPreferencesProvider.future),
        container.read(listeningServiceProvider).prepareVoices().timeout(
          kTtsPageConnectionWait,
          onTimeout: () => [],
        ),
      ]);
    } finally {
      preferences.close();
    }
  } else if (panel == ReaderPanel.brightness) {
    await Future.wait([
      container.read(systemBrightnessProvider.future),
      container.read(readingControlsProvider.future),
      container.read(readingBackgroundsProvider.future),
    ]);
  }
}
