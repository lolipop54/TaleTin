import 'package:flutter/material.dart';

import '../../../../domain/models/reading_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';
import 'reader_desktop_layout.dart';

/// 使用本地透明缩略图；顺序与翻页设置枚举一致，完整卡片都能点击。
class ReaderTurnChoices extends StatelessWidget {
  const ReaderTurnChoices({
    super.key,
    required this.selected,
    required this.onSelect,
    this.curlOnly = false,
    this.effects = PageTurnEffect.values,
  });
  final PageTurnEffect selected;
  final bool curlOnly;
  final List<PageTurnEffect> effects;
  final ValueChanged<PageTurnEffect> onSelect;

  static ImageProvider image(PageTurnEffect effect, double pixelRatio) =>
      ResizeImage(
        AssetImage('assets/pics/${effect.label}.webp'),
        width: (80 * pixelRatio).ceil(),
      );

  static Future<void> prepare(
    BuildContext context, {
    List<PageTurnEffect> effects = PageTurnEffect.values,
  }) => Future.wait([
    for (final effect in effects)
      precacheImage(
        image(effect, MediaQuery.devicePixelRatioOf(context)),
        context,
      ),
  ]);

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    if (readerUsesDesktopPanels) {
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      return Column(
        children: [
          for (final effect in effects)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: GtButton.raw(
                key: ValueKey('reader-turn-${effect.name}'),
                selected: effect == selected,
                borderRadius: BorderRadius.circular(8),
                onPressed: curlOnly && effect != PageTurnEffect.curl
                    ? null
                    : () => onSelect(effect),
                child: Container(
                  decoration: BoxDecoration(
                    color: effect == selected
                        ? colors.actionPrimary.withValues(alpha: .10)
                        : null,
                    border: Border.all(
                      color: effect == selected
                          ? colors.actionPrimary
                          : colors.borderSubtle,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Image(
                        image: image(effect, pixelRatio),
                        width: 26,
                        height: 32,
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          effect.label,
                          style: GtText.body(colors.textPrimary),
                        ),
                      ),
                      if (effect == selected)
                        GtIcon(
                          GtIcons.checkCircle,
                          size: 18,
                          color: colors.actionPrimary,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: Row(
        children: [
          for (final effect in effects)
            Semantics(
              selected: effect == selected,
              child: GtButton.raw(
                key: ValueKey('reader-turn-${effect.name}'),
                selected: effect == selected,
                onPressed: curlOnly && effect != PageTurnEffect.curl
                    ? null
                    : () => onSelect(effect),
                child: Opacity(
                  opacity: curlOnly && effect != PageTurnEffect.curl ? 0.35 : 1,
                  child: SizedBox(
                    width: 80,
                    child: Column(
                      children: [
                        Container(
                          // padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(GtRadius.cover),
                            border: Border.all(
                              width: 1.5,
                              color: effect == selected
                                  ? context.gtColors.actionPrimary
                                  : Colors.transparent,
                            ),
                          ),
                          child: Stack(
                            children: [
                              Image(
                                image: image(
                                  effect,
                                  MediaQuery.devicePixelRatioOf(context),
                                ),
                                width: 60,
                                height: 79,
                                fit: BoxFit.contain,
                                excludeFromSemantics: true,
                              ),
                              if (effect == selected)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: GtIcon(
                                    GtIcons.checkCircle,
                                    size: 18,
                                    color: context.gtColors.actionPrimary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          effect.label,
                          textAlign: TextAlign.center,
                          style: GtText.caption(colors.textPrimary)
                              .copyWith(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
