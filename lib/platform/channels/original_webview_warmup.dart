import 'dart:async';
import 'dart:io';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../../core/diagnostics/opening_experiments.dart';

/// 书架就绪且动画结束后，提前执行 WebView 可以在后台完成的启动工作。
/// 不创建空白页面，也不把必须在界面线程做的初始化搬到书架。
abstract final class OriginalWebViewWarmup {
  static const _channel = MethodChannel('gtreader/original-startup');
  static Future<bool>? _task;
  static Future<bool> schedule({bool Function()? allowed}) {
    // 后台启动接口只在 Android 注册，桌面组件测试也不应安排这项空闲任务。
    if (!Platform.isAndroid || !OpeningExperiments.warmWebView) {
      return Future.value(false);
    }
    return _task ??= SchedulerBinding.instance.scheduleTask(() async {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if ((lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
          allowed?.call() == false) {
        return false;
      }
      try {
        await _channel.invokeMethod<void>('warmup').timeout(const Duration(seconds: 5));
        return true;
      } on Exception {
        // 预热是可选准备；正常打开仍由现有原书流程负责。
        return false;
      }
    }, Priority.idle, debugLabel: 'original-webview-startup');
  }
}
