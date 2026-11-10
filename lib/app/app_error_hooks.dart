import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics/app_errors.dart';
import '../core/diagnostics/app_resume_diagnostics.dart';

/// Binding 与 runApp 必须在同一个 Zone 内；保留 Flutter 原来的控制台报告。
void runWithAppErrors(VoidCallback start) {
  runZonedGuarded(
    () {
      final binding = WidgetsFlutterBinding.ensureInitialized();
      installAppErrorHandlers();
      final resumeDiagnostics = AppResumeDiagnostics();
      var started = false;
      void startWhenWindowReady(AppLifecycleState? state) {
        // Android 的媒体服务可能先启动 Flutter。等 Activity 接好平台通道后，
        // 才挂载应用并准备首帧。启动画面还盖着窗口时就可能收到 inactive。
        if (started ||
            (Platform.isAndroid &&
                state != AppLifecycleState.inactive &&
                state != AppLifecycleState.resumed)) {
          return;
        }
        started = true;
        AppResumeDiagnostics.record('start');
        unawaited(AppErrors.initialize());
        start();
      }

      // 后台错误仍记录，回前台再提示；不在后台持续调用系统 Toast。
      AppLifecycleListener(
        binding: binding,
        onStateChange: (state) {
          resumeDiagnostics.onStateChange(state);
          AppErrors.reporter.setForeground(state == AppLifecycleState.resumed);
          startWhenWindowReady(state);
        },
      );
      startWhenWindowReady(binding.lifecycleState);
    },
    (error, stack) {
      AppErrors.report(error, stack, operation: '应用运行异常');
    },
  );
}

void installAppErrorHandlers() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    AppErrors.report(
      details.exception,
      details.stack ?? StackTrace.current,
      operation: '界面显示异常',
    );
    (previous ?? FlutterError.presentError)(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppErrors.report(error, stack, operation: '未完成的异步操作');
    return true;
  };
}

/// Provider 内部会接住 Future/Stream 错误，单靠全局未捕获入口看不到它们。
final class AppErrorObserver extends ProviderObserver {
  const AppErrorObserver();
  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    AppErrors.report(error, stackTrace, operation: '读取应用数据');
  }
}
