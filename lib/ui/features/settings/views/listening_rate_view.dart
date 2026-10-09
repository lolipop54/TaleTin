import 'package:taletin/ui/core/theme/gt_tokens.dart';
import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../reader/view_models/listening_panel_view_model.dart';
import '../../reader/view_models/listening_view_state.dart';
import '../widgets/settings_slider.dart';

class ListeningRateView extends ConsumerWidget {
  const ListeningRateView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speech = ref.watch(listeningViewStateProvider).requireValue;
    return Scaffold(
      appBar: GtAppBar(title: const Text('语速')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SettingsSlider(
            thumbRadius: GtSliderSize.thumbRadiusSmall,
            trackThickness: GtSliderSize.trackThicknessSmall,
            label: '语速',
            value: speech.speed,
            min: .5,
            max: 2,
            divisions: 15,
            format: (v) => '${v.toStringAsFixed(1)}×',
            save: (v) =>
                ref.read(listeningPanelProvider(speech.bookId)).rate(v),
          ),
        ),
      ),
    );
  }
}
