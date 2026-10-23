import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';

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
