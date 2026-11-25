import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';

import 'windows_settings_layout.dart';

/// 桌面操作按钮按名称取宽，窄窗自动换行；手机继续使用纵向铺满的按钮。
Widget settingsActions(BuildContext context, List<Widget> actions) =>
    WindowsSettingsPane.contains(context)
    ? Wrap(spacing: 8, runSpacing: 8, children: actions)
    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: actions);

/// 设置失败只显示系统短提示，保存和失败恢复仍由调用方负责。
Future<void> saveSetting(
  BuildContext context,
  Future<void> Function() save,
) async {
  try {
    await save();
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '设置未保存，请重试', notify: false);
    if (context.mounted) {
      AppErrors.report(appError, appStack, operation: '设置未保存，请重试');
    }
  }
}
