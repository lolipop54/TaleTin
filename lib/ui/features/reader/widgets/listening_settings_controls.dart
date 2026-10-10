import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:taletin/ui/core/theme/app_theme.dart';
import 'package:taletin/ui/core/theme/gt_tokens.dart';

import '../view_models/listening_panel_view_model.dart';
import '../view_models/listening_view_state.dart';
import 'listening_option_sheet.dart';
import 'reader_sheet.dart';
import '../../settings/widgets/settings_slider.dart';

class ListeningSettingsControls extends ConsumerStatefulWidget {
  const ListeningSettingsControls({super.key, required this.bookId});
  final String bookId;
  @override
  ConsumerState<ListeningSettingsControls> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<ListeningSettingsControls> {
  @override
  Widget build(BuildContext context) {
    final speech = ref.watch(listeningViewStateProvider).value;
    final voice = speech?.voice;
    final rate = speech?.speed ?? 1;
    final commands = ref.watch(listeningPanelProvider(widget.bookId));
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 8),
          SettingsSlider(
            trackThickness: GtSliderSize.trackThicknessSmall,
            thumbRadius: GtSliderSize.thumbRadiusSmall,
            key: const Key('tts-rate'),
            compact: true,
            backgroundColor: ReaderSheet.backgroundOf(context),
            label: '语速',
            labelStyle: GtText.body(context.gtColors.textPrimary)
                .copyWith(fontSize: 14),
            value: rate,
            min: .5,
            max: 2,
            divisions: 15,
            format: (v) => '${v.toStringAsFixed(1)}×',
            save: voice == null ? null : commands.rate,
          ),
          const SizedBox(height: 6),
          ListTile(
            minTileHeight: 56,
            contentPadding: EdgeInsets.zero,
            title: const Text('音色', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              voice == null
                  ? '尚无可用音色，点击选择或安装'
                  : '${voice.displayName} · ${voice.locale}',
              style: TextStyle(fontSize: 12),
            ),
            trailing: const Text('选择'),
            onTap: () => showListeningVoice(context, ref, widget.bookId),
          ),
        ],
      ),
    );
  }
}
