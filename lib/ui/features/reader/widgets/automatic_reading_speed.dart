import 'package:flutter/material.dart';

import '../../../../domain/models/reading_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';

import '../../settings/widgets/settings_slider.dart';
import 'reader_sheet.dart';

/// 扫描耗时反向映射：左侧慢、右侧快，松手才保存实际秒数。
class AutomaticReadingSpeed extends StatelessWidget {
  const AutomaticReadingSpeed({
    super.key,
    required this.settings,
    required this.onScrollSpeed,
    required this.onScanSeconds,
    this.pendingSave,
  });
  final ReadingSettings settings;
  final Future<void> Function()? pendingSave;
  final ValueChanged<double> onScrollSpeed;
  final ValueChanged<int> onScanSeconds;
  @override
  Widget build(BuildContext context) {
    final scrolling = settings.pageTurnEffect == PageTurnEffect.scroll;
    final colors = context.gtColors;
    return SettingsSlider(
      key: const Key('automatic-speed'),
      labelPosition: SliderLabelPosition.above,
      thumbRadius: GtSliderSize.thumbRadiusLarge,
      trackThickness: GtSliderSize.trackThicknessLarge,
      compact: true,
      backgroundColor: ReaderSheet.backgroundOf(context),
      label: scrolling ? '滚动速度' : '每页扫描耗时',
      labelStyle: GtText.body(context.gtColors.textPrimary)
          .copyWith(fontSize: 14),
      value: scrolling
          ? settings.autoScrollSpeed
          : 32 - settings.autoScanSeconds.toDouble(),
      min: scrolling ? 12 : 2,
      max: scrolling ? 80 : 30,
      divisions: scrolling ? 68 : 28,
      format: (v) => scrolling ? '${v.round()}' : '${(32 - v).round()}秒',
      leading: Text('慢', style: GtText.caption(colors.textSecondary)),
      trailing: Text('快', style: GtText.caption(colors.textSecondary)),
      save: (v) async {
        if (scrolling) {
          onScrollSpeed(v);
        } else {
          onScanSeconds((32 - v).round());
        }
        await pendingSave?.call();
      },
    );
  }
}
