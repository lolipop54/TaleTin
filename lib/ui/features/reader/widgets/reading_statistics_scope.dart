import 'dart:async';
import 'package:taletin/core/diagnostics/app_errors.dart';
import 'turn_trace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/di/statistics_providers.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../platform/channels/reading_window.dart';
import '../../../../domain/services/reading_statistics_service.dart';
import '../view_models/automatic_reading.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_source_change.dart';

/// 只上报界面事实；计时、超时与存储属于应用服务。此组件不随排版模式替换。
class ReadingStatisticsScope extends ConsumerStatefulWidget {
  const ReadingStatisticsScope({super.key, required this.bookId,
    required this.ready, required this.child, this.onVolumeTurn});
  final Future<void> Function(bool forward)? onVolumeTurn;
  final String bookId;
  final bool Function() ready;
  final Widget child;
  @override
  ConsumerState<ReadingStatisticsScope> createState() => _StatisticsScopeState();
}

class _StatisticsScopeState extends ConsumerState<ReadingStatisticsScope> {
  late final ReadingStatisticsService service;
  late final AppLifecycleListener lifecycle;
  late final Timer readiness;
  bool foreground = true, currentRoute = true;
  final _opening = Stopwatch()..start();
  bool _loggedReady = false;
  Object? shownError;
  late final ReadingWindow window;
  final awakeOwner = Object();
  bool _awake = false, _keys = false, _turning = false;
  (bool, bool)? _bars;

  @override
  void initState() {
    super.initState();
    service = ref.read(readingStatisticsServiceProvider);
    window = ref.read(readingWindowProvider);
    ReadingWindow.channel.setMethodCallHandler((call) async {
      if (call.method != 'turn' || !_keys || _turning) return;
      sync(interaction: true);
      if (!_keys) return;
      _turning = true;
      try { await widget.onVolumeTurn?.call(call.arguments == true); }
      catch (error, stack) {
        AppErrors.report(error, stack, operation: '音量键翻页失败', notify: mounted);
        if (mounted) ref.read(readerProvider.notifier).showNotice('翻页失败，请重试');
      }
      finally { _turning = false; }
    });
    foreground = WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    lifecycle = AppLifecycleListener(onStateChange: (state) {
      foreground = state == AppLifecycleState.resumed;
      // 解锁或从桌面回来时重新应用阅读设置，不能依赖系统保留隐藏状态。
      if (foreground) _bars = null;
      sync();
    });
    // WebView 的实际就绪不一定引发 Flutter 重建；只检查状态，不累计时长。
    readiness = Timer.periodic(const Duration(milliseconds: 100), (_) => sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    currentRoute = ModalRoute.isCurrentOf(context) ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) sync(); });
  }

  void sync({bool interaction = false}) {
    if (!mounted) return;
    final reader = ref.read(readerProvider);
    final auto = ref.read(automaticReadingProvider(widget.bookId));
    if (!_loggedReady && widget.ready()) {
      _loggedReady = true;
      traceTurn('load first-readable us=${_opening.elapsedMicroseconds}');
    }
    final visible = !ref.read(readerSourceChangeProvider(widget.bookId)) &&
      foreground && currentRoute && widget.ready() &&
      !reader.controlsVisible && reader.panel == ReaderPanel.none &&
      reader.note == null && reader.selection == null;
    final controls = ref.read(readingControlsProvider).value;
    // 锁屏、切后台和阅读内弹层都保留系统栏设置。若失去前台时显示系统栏，
    // 回来再隐藏，正文会按临时高度重排，页首反复取整就会退到前一页。
    // 真正退出阅读时才恢复系统栏；计时和音量键仍只在正文前台生效。
    final bars = (controls?.statusBar ?? true, controls?.navigationBar ?? true);
    if (_bars != bars) {
      _bars = bars;
      unawaited(window.systemBars(status: bars.$1, navigation: bars.$2));
    }
    // 常亮属于整个前台阅读页，不能跟随统计的“正文无遮挡”条件。
    // 调整面板、选文或等待重排时同样需要保持亮屏。
    final readingRoute = currentRoute || reader.panelCovered ||
        reader.panel == ReaderPanel.search;
    final awake = foreground && readingRoute && !window.exiting.value &&
        controls?.keepAwake == true;
    final keys = visible && controls?.volumeKeys == true && widget.onVolumeTurn != null;
    if (awake != _awake) {
      _awake = awake; unawaited(window.keepAwake(awakeOwner, awake));
    }
    if (keys != _keys) {
      _keys = keys; unawaited(window.volumeKeys(keys));
    }
    service.setVisual(widget.bookId,
      visible: visible,
      automatic: auto.running || auto.preparing, advancing: auto.advancing,
      interaction: interaction);
    final error = service.saveError;
    if (error != null && !identical(error, shownError)) {
      shownError = error;
      ref.read(readerProvider.notifier).showNotice('阅读统计暂未保存，正在重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(readingControlsProvider);
    ref.listen(readerProvider, (_, _) => sync());
    ref.listen(automaticReadingProvider(widget.bookId), (_, _) => sync());
    return Listener(behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => sync(interaction: true),
      onPointerMove: (_) => sync(interaction: true),
      onPointerUp: (_) => sync(interaction: true), child: widget.child);
  }

  @override
  void dispose() {
    readiness.cancel(); lifecycle.dispose();
    ReadingWindow.channel.setMethodCallHandler(null);
    unawaited(window.volumeKeys(false));
    unawaited(window.systemBars(status: true, navigation: true));
    unawaited(window.keepAwake(awakeOwner, false));
    // 正常退出已显式等待保存；意外移除仅同步结算，交给现有心跳提交。
    service.detachVisual();
    super.dispose();
  }
}
