import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../domain/repositories/app_theme_repository.dart';
import '../ui/core/theme/app_theme.dart';
import '../ui/core/theme/forui_theme.dart';
import '../ui/core/theme/gt_tokens.dart';

/// 位于 MaterialApp 外的恢复遮盖，需要自行应用当前主题。
class RestoreStatusOverlay extends StatelessWidget {
  const RestoreStatusOverlay({
    super.key,
    required this.mode,
    required this.busy,
    required this.message,
    required this.onDismiss,
    this.fatal = false,
    this.fontFamily,
  });
  final AppThemeMode mode;
  final String? fontFamily;
  final bool busy, fatal;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dark =
        mode == AppThemeMode.dark ||
        (mode == AppThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    final theme = dark ? GtTheme.dark(fontFamily: fontFamily)
        : GtTheme.light(fontFamily: fontFamily);
    final c = theme.extension<GtColors>()!;
    return Theme(
      data: theme,
      child: GtForuiTheme(child: Material(
        color: busy || fatal ? c.scrim : Colors.transparent,
        child: Align(
          alignment: busy || fatal ? Alignment.center : Alignment.bottomCenter,
          child: SafeArea(
            child: Card(
              color: c.surface,
              surfaceTintColor: Colors.transparent,
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(message, style: GtText.body(c.textPrimary, family: fontFamily)),
                    if (busy)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: LinearProgressIndicator(
                          color: c.actionPrimary,
                          backgroundColor: c.subtle,
                        ),
                      ),
                    if (!busy && !fatal)
                      GtButton(
                        onPressed: onDismiss,
                        child: const Text('知道了'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      )),
    );
  }
}
