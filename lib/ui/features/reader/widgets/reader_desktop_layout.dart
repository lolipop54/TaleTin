import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';

bool get readerUsesDesktopPanels =>
    defaultTargetPlatform == TargetPlatform.windows;

const readerDesktopHeaderHeight = 54.0;
const readerDesktopHeaderBottomBorder = 1.0;
const _desktopChapterTitleHeight = 22.0;
const readerDesktopProgressHeight =
    _desktopChapterTitleHeight + DesktopReaderActionButton.size;
const readerDesktopPanelMargin = 14.0;

/// 面板覆盖在正文之上，切换工具时不会重新排版或移动阅读位置。
class DesktopReaderPanelSurface extends StatelessWidget {
  const DesktopReaderPanelSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final radius = BorderRadius.circular(14);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: radius,
        border: Border.all(color: colors.borderSubtle),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .14),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: radius,
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

class DesktopReaderActionButton extends StatelessWidget {
  const DesktopReaderActionButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  static const size = 42.0;
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final color = context.gtColors.textPrimary;
    // 阅读控制栏底色之上提供独立的绘制面，避免反馈被纸面挡住。
    return Material(
      type: MaterialType.transparency,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: icon,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(size),
          minimumSize: const Size.square(size),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const CircleBorder(),
          foregroundColor: color,
          hoverColor: color.withValues(alpha: .10),
          focusColor: color.withValues(alpha: .14),
          highlightColor: color.withValues(alpha: .18),
          enabledMouseCursor: SystemMouseCursors.click,
          splashFactory: MediaQuery.disableAnimationsOf(context)
              ? NoSplash.splashFactory
              : InkRipple.splashFactory,
        ),
      ),
    );
  }
}

class DesktopReaderProgress extends StatelessWidget {
  const DesktopReaderProgress({
    super.key,
    required this.theme,
    required this.chapter,
    required this.progress,
    required this.slider,
    required this.onPrevious,
    required this.onNext,
  });

  final ReadingTheme theme;
  final String chapter;
  final double progress;
  final Widget slider;
  final VoidCallback onPrevious, onNext;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final label = GtText.caption(theme.secondary).copyWith(fontSize: 13);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.background,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      child: SizedBox(
        height: readerDesktopProgressHeight,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Row(
                      children: [
                        DesktopReaderActionButton(
                          tooltip: '上一章',
                          onPressed: onPrevious,
                          icon: const Icon(Icons.chevron_left, size: 20),
                        ),
                        DesktopReaderActionButton(
                          tooltip: '下一章',
                          onPressed: onNext,
                          icon: const Icon(Icons.chevron_right, size: 20),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: slider,
                          ),
                        ),
                        // 两侧等宽保证居中，百分比贴近滑轨这一侧。
                        SizedBox(
                          width: DesktopReaderActionButton.size * 2,
                          child: Text(
                            '${(progress * 100).toStringAsFixed(2)}%',
                            textAlign: TextAlign.start,
                            style: label,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 用滑轨上沿算出两侧等量留白，固定行高保证切章时位置稳定。
                  Positioned(
                    top:
                        (DesktopReaderActionButton.size -
                            GtSliderSize.trackThicknessSmall) /
                        4,
                    left: DesktopReaderActionButton.size * 2,
                    right: DesktopReaderActionButton.size * 2,
                    height: _desktopChapterTitleHeight,
                    child: Center(
                      child: Text(
                        chapter,
                        key: const ValueKey('windows-reader-chapter-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: label,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
