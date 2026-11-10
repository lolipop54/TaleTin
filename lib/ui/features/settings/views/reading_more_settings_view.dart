import 'package:flutter/material.dart';

import '../../../core/widgets/gt_app_bar.dart';
import '../widgets/reading_controls_options.dart';

class ReadingMoreSettingsView extends StatelessWidget {
  const ReadingMoreSettingsView({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: GtAppBar(title: const Text('更多设置')),
    body: const SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: ReadingControlsOptions(),
      ),
    ),
  );
}
