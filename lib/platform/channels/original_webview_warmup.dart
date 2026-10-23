import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/diagnostics/opening_experiments.dart';
import '../../core/diagnostics/reader_work_trace.dart';
import '../../core/diagnostics/reader_delivery_experiments.dart';
import 'preset_fonts.dart';

/// 共享后台内核准备；启动画面下可额外准备一个供首次阅读直接接手的实例。
abstract final class OriginalWebViewWarmup {
  static const _channel = MethodChannel('gtreader/original-startup');
  // 与原书分页共用同一宿主地址；这里只加载框架，不登记任何书籍资源。
  static const pagedShellUrl =
      'https://gtbook.internal${PresetFonts.webViewAssetPrefix}'
      'flutter_assets/assets/webview/paged_host.html';
  static Future<bool>? _task;
  static Future<bool>? _scheduled;
  static bool _finished = false;
  static HeadlessInAppWebView? _firstView;
  static Future<void>? _viewTask;
  static int _viewGeneration = 0;
  static final _memoryObserver = _FirstViewMemoryObserver();
  static bool get isPrepared => !Platform.isAndroid || _finished;
  static bool get canPrepareFirstView =>
      Platform.isAndroid && OpeningExperiments.warmWebView;

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

  /// 启动准备和实际开书共用至多一个任务。没有可交付实例时可以按需补充，
  /// 准备耗时仍计入这次开书，不在书架上额外安排实例创建。
  static Future<void> prepareFirstView(InAppWebViewSettings settings) {
    if (!canPrepareFirstView || _firstView != null) return Future.value();
    return _viewTask ??= _prepareFirstView(settings)
        .whenComplete(() => _viewTask = null);
  }

  static Future<void> _prepareFirstView(InAppWebViewSettings settings) async {
    final generation = _viewGeneration;
    // 准备期间也可能收到内存压力；不能等实例已经就绪才开始监听。
    WidgetsBinding.instance.addObserver(_memoryObserver);
    final trace = ReaderWorkTrace.start('webview.first_view');
    final loaded = Completer<void>();
    final reuseShell = ReaderDeliveryExperiments.originalPagedShell;
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
        initialUrlRequest: reuseShell
            ? URLRequest(url: WebUri(pagedShellUrl))
            : null,
        initialData: reuseShell
            ? null
            : InAppWebViewInitialData(
                data:
                    '<!doctype html><body style="margin:0;background:#eee;font:10px sans-serif">'
                    '<img width="8" height="8" src="data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%228%22 height=%228%22%3E%3Crect width=%228%22 height=%228%22 fill=%22%23579%22/%3E%3C/svg%3E">字</body>',
              ),
        shouldInterceptRequest: !reuseShell
            ? null
            : (_, request) async {
                final uri = request.url;
                final name = uri.pathSegments.lastOrNull;
                if (uri.host == 'gtbook.internal' &&
                    uri.path.startsWith(
                      '${PresetFonts.webViewAssetPrefix}flutter_assets/assets/webview/',
                    ) &&
                    (name == 'paged_host.html' || name == 'paged_host.js')) {
                  final data = await rootBundle.load('assets/webview/$name');
                  return WebResourceResponse(
                    contentType: name == 'paged_host.html'
                        ? 'text/html'
                        : 'application/javascript',
                    contentEncoding: 'utf-8',
                    data: data.buffer.asUint8List(
                      data.offsetInBytes,
                      data.lengthInBytes,
                    ),
                  );
                }
                return WebResourceResponse(
                  contentType: 'text/plain',
                  data: Uint8List(0),
                );
              },
        onLoadStop: (controller, _) async {
          if (expired || loaded.isCompleted) return;
          if (!reuseShell) {
            loaded.complete();
            return;
          }
          final ready = await controller.evaluateJavascript(
            source: '!!window.__gtPager',
          );
          if (!expired && ready == true && !loaded.isCompleted) {
            loaded.complete();
          }
        },
      );
      await candidate!.run();
      trace?.mark('create_instance');
      await loaded.future;
      trace?.mark('load_shell');
      if (!expired) {
        try {
          // 在真正外壳中预绘制同样的小图、文字和背景。接手前移除临时内容，
          // 保留已加载的三个iframe和脚本，阅读时无需再次导航顶层文档。
          if (reuseShell) {
            await candidate!.webViewController!.callAsyncJavaScript(
              functionBody: r'''
            const probe = document.createElement('div');
            probe.id = 'gt-first-view-probe';
            probe.style.cssText = 'position:absolute;inset:0;background:#eee;font:10px sans-serif';
            const image = document.createElement('img');
            image.width = image.height = 8;
            image.src = 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%228%22 height=%228%22%3E%3Crect width=%228%22 height=%228%22 fill=%22%23579%22/%3E%3C/svg%3E';
            probe.append(image, document.createTextNode('字'));
            document.body.appendChild(probe);
            await image.decode();
          ''',
            );
          }
          final drawn = await _channel.invokeMapMethod<String, Object?>(
            'drawPrepared',
            {'id': candidate!.id},
          );
          if (trace != null && drawn != null) trace.details.addAll(drawn);
          trace?.mark('first_draw');
        } on Exception catch (error) {
          // 个别驱动不能离屏硬件绘制时，仍交付已创建好的实例，正常页面照常绘制。
          trace?.details['drawFailure'] = error.runtimeType.toString();
        } finally {
          if (reuseShell) {
            await candidate!.webViewController!.evaluateJavascript(
              source:
                  "document.getElementById('gt-first-view-probe')?.remove()",
            );
          }
        }
      }
      if (expired) await candidate!.dispose();
    }

    try {
      await create().timeout(const Duration(seconds: 2));
      if (generation != _viewGeneration) {
        trace?.details['discarded'] = 'memory_pressure';
        await candidate?.dispose();
        return;
      }
      _firstView = candidate;
      trace?.details['prepared'] = candidate != null;
    } on Exception catch (error) {
      expired = true;
      if (!loaded.isCompleted) loaded.complete();
      trace?.details['failure'] = error.runtimeType.toString();
    } finally {
      if (_firstView == null) {
        WidgetsBinding.instance.removeObserver(_memoryObserver);
      }
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
    // 内存压力期间已经开始的准备，完成后也不能重新放回实例槽。
    _viewGeneration++;
    await takeFirstView()?.dispose();
  }
}

class _FirstViewMemoryObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    unawaited(OriginalWebViewWarmup.releaseFirstView());
  }
}
