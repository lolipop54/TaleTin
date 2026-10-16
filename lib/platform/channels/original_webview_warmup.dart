import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/diagnostics/opening_experiments.dart';
import '../../core/diagnostics/reader_work_trace.dart';

/// 共享后台内核准备；启动画面下可额外准备一个供首次阅读直接接手的实例。
abstract final class OriginalWebViewWarmup {
  static const _channel = MethodChannel('gtreader/original-startup');
  static Future<bool>? _task;
  static Future<bool>? _scheduled;
  static bool _finished = false;
  static HeadlessInAppWebView? _firstView;
  static final _memoryObserver = _FirstViewMemoryObserver();
  static bool get isPrepared => !Platform.isAndroid || _finished;

  /// 立即开书接管同一准备任务，不等待尚未执行的书架空闲回调。
  static Future<bool> ensureReady() {
    if (!Platform.isAndroid || !OpeningExperiments.warmWebView) {
      return Future.value(false);
    }
    return _task ??= _start();
  }

  static Future<bool> schedule({bool Function()? allowed}) {
    // 后台启动接口只在 Android 注册，桌面组件测试也不应安排这项空闲任务。
    if (!Platform.isAndroid || !OpeningExperiments.warmWebView) {
      return Future.value(false);
    }
    if (_task != null) return _task!;
    return _scheduled ??= SchedulerBinding.instance
        .scheduleTask(
          () async {
            final lifecycle = WidgetsBinding.instance.lifecycleState;
            if ((lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
                allowed?.call() == false) {
              return false;
            }
            return ensureReady();
          },
          Priority.idle,
          debugLabel: 'original-webview-startup',
        )
        .whenComplete(() => _scheduled = null);
  }

  static Future<bool> _start() async {
    final trace = ReaderWorkTrace.start('webview.warmup');
    try {
      final result = await _channel
          .invokeMapMethod<String, Object?>('warmup', {
            'trace': readerWorkTraceEnabled,
          })
          .timeout(const Duration(seconds: 5));
      if (trace != null && result != null) trace.details.addAll(result);
      return true;
    } on Exception catch (error) {
      // 不支持或准备失败时仍允许标准 WebView 打开，不让加载层无限等待。
      trace?.details['failure'] = error.runtimeType.toString();
      return false;
    } finally {
      _finished = true;
      trace?.finish();
    }
  }

  /// 只在静态系统启动画面仍被保留时调用，不在书架动画或加载动画中创建。
  /// 限时失败后沿用普通开书，迟到的实例会销毁，不重新放回准备槽。
  static Future<void> prepareFirstView(InAppWebViewSettings settings) async {
    if (!Platform.isAndroid || !OpeningExperiments.warmWebView) return;
    final trace = ReaderWorkTrace.start('webview.first_view');
    final loaded = Completer<void>();
    HeadlessInAppWebView? candidate;
    var expired = false;
    Future<void> create() async {
      await ensureReady();
      if (expired) return;
      if (const bool.fromEnvironment('GT_TRACE_WEBVIEW_DEBUG')) {
        await InAppWebViewController.setWebContentsDebuggingEnabled(true);
      }
      candidate = HeadlessInAppWebView(
        initialSize: const Size(32, 32),
        initialSettings: settings,
        // 图片、文字及背景先走一次真实硬件绘制，避免首屏再初始化图形缓存。
        initialData: InAppWebViewInitialData(
          data:
              '<!doctype html><body style="margin:0;background:#eee;font:10px sans-serif">'
              '<img width="8" height="8" src="data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%228%22 height=%228%22%3E%3Crect width=%228%22 height=%228%22 fill=%22%23579%22/%3E%3C/svg%3E">字</body>',
        ),
        onLoadStop: (_, _) {
          if (!loaded.isCompleted) loaded.complete();
        },
      );
      await candidate!.run();
      await loaded.future;
      if (!expired) {
        try {
          final drawn = await _channel.invokeMapMethod<String, Object?>(
            'drawPrepared',
            {'id': candidate!.id},
          );
          if (trace != null && drawn != null) trace.details.addAll(drawn);
        } on Exception catch (error) {
          // 个别驱动不能离屏硬件绘制时，仍交付已创建好的实例，正常页面照常绘制。
          trace?.details['drawFailure'] = error.runtimeType.toString();
        }
      }
      if (expired) await candidate!.dispose();
    }

    try {
      await create().timeout(const Duration(seconds: 2));
      _firstView = candidate;
      WidgetsBinding.instance.addObserver(_memoryObserver);
      trace?.details['prepared'] = candidate != null;
    } on Exception catch (error) {
      expired = true;
      if (!loaded.isCompleted) loaded.complete();
      trace?.details['failure'] = error.runtimeType.toString();
    } finally {
      trace?.finish();
    }
  }

  /// 只交付一次；接手后的生命周期由插件和实际阅读组件管理。
  static HeadlessInAppWebView? takeFirstView() {
    final view = _firstView;
    _firstView = null;
    WidgetsBinding.instance.removeObserver(_memoryObserver);
    return view;
  }

  static Future<void> releaseFirstView() async {
    await takeFirstView()?.dispose();
  }
}

class _FirstViewMemoryObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    unawaited(OriginalWebViewWarmup.releaseFirstView());
  }
}
