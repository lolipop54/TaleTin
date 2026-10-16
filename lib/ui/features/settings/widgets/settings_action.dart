import 'package:flutter/material.dart';
import 'package:taletin/platform/channels/system_toast.dart';

/// 设置失败只显示系统短提示，保存和失败恢复仍由调用方负责。
Future<void> saveSetting(
  BuildContext context,
  Future<void> Function() save,
) async {
  try {
    await save();
  } catch (_) {
    if (context.mounted) {
      SystemToast.show('设置未保存，请重试').ignore();
    }
  }
}
