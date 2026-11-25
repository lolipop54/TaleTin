import 'dart:async';
import 'dart:io';

import 'package:taletin/core/diagnostics/app_errors.dart';

import '../../../../core/diagnostics/reader_turn_state_diagnostics.dart';

import 'turn_trace.dart';
import 'desktop_reading_input.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/statistics_providers.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../platform/channels/reading_window.dart';
import '../../../../platform/channels/windows_wheel_modifier.dart';
import '../../../../domain/services/reading_statistics_service.dart';
import '../view_models/automatic_reading.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_source_change.dart';
import '../view_models/reader_session_view_model.dart';
import '../../../../domain/models/locator.dart';
import '../../../../core/diagnostics/reader_recovery_diagnostics.dart';

/// 只上报界面事实；计时、超时与存储属于应用服务。此组件不随排版模式替换。
class ReadingStatisticsScope extends ConsumerStatefulWidget {
  const ReadingStatisticsScope({
    super.key,
    required this.bookId,
    required this.ready,
    required this.child,
    this.onVolumeTurn,
    this.desktopScrolling,
    this.onDesktopScroll,
    this.onDesktopZoom,
    this.wheelReadyDetails,
  });
  final Future<void> Function(bool forward)? onVolumeTurn;
  final bool? desktopScrolling;
  final Future<void> Function(double delta)? onDesktopScroll;
  final void Function(double delta, Offset position)? onDesktopZoom;
  final String bookId;
  final Map<String, Object?> Function()? wheelReadyDetails;
  final bool Function() ready;
  final Widget child;
  @override
  ConsumerState<ReadingStatisticsScope> createState() =>
      _StatisticsScopeState();
}

class _StatisticsScopeState extends ConsumerState<ReadingStatisticsScope>
    with WidgetsBindingObserver {
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
  Locator? _backgroundAnchor;
  final _recoveryChecks = <Timer>[];

  Map<String, Object?> _recoverySnapshot() {
    final s = ref.read(readerSessionProvider(widget.bookId)).value;
    final anchor = s?.currentAnchor;
    final view = View.of(context);
    final bars = ref.read(readingControlsProvider).value;
    return {
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
      'foreground': foreground,
      'routeCurrent': currentRoute,
      'physicalWidth': view.physicalSize.width,
      'physicalHeight': view.physicalSize.height,
      'dpr': view.devicePixelRatio,
      'padding': [
        view.padding.left,
        view.padding.top,
        view.padding.right,
        view.padding.bottom,
      ],
      'viewPadding': [
        view.viewPadding.left,
        view.viewPadding.top,
        view.viewPadding.right,
        view.viewPadding.bottom,
      ],
      'viewInsets': [
        view.viewInsets.left,
        view.viewInsets.top,
        view.viewInsets.right,
        view.viewInsets.bottom,
      ],
      'requestedStatus': bars?.statusBar,
      'requestedNavigation': bars?.navigationBar,
      'format': s?.book.format.name,
      'chapter': s?.chapterIndex,
      'page': s?.pageIndex,
      'pages': s?.pageCount,
      'originalFraction': s?.originalFraction,
      'scrolling': s?.scrolling,
      'original': s?.isOriginal,
      'layoutIdentity': s?.layout?.identity.hashCode,
      'viewportSignature': s?.viewportSignature?.hashCode,
      'offset': anchor?.utf16Offset,
      'anchorPresent': anchor != null,
      'sameBackgroundPosition': anchor != null && _backgroundAnchor != null
          ? anchor.samePosition(_backgroundAnchor!)
          : null,
      'sameBackgroundBlock': anchor != null && _backgroundAnchor != null
          ? anchor.chapterId == _backgroundAnchor!.chapterId &&
                anchor.blockId == _backgroundAnchor!.blockId
          : null,
    };
  }

  void _recovery(String event) {
    if (!ReaderRecoveryDiagnostics.observing || !mounted) return;
    ReaderRecoveryDiagnostics.record(event, _recoverySnapshot());
  }

  @override
  void didChangeMetrics() {
    _recovery('flutterMetrics');
    ReaderRecoveryDiagnostics.nativeSnapshot('flutterMetrics');
  }

  @override
  void initState() {
    super.initState();
    service = ref.read(readingStatisticsServiceProvider);
    window = ref.read(readingWindowProvider);
    if (readerTurnStateDiagnosticsEnabled) {
      ReaderTurnStateDiagnostics.attach(this, 'desktopInput', _wheelState);
    }
    if (readerRecoveryDiagnosticsEnabled) {
      ReaderRecoveryDiagnostics.attach(this);
      WidgetsBinding.instance.addObserver(this);
    }
    ReadingWindow.channel.setMethodCallHandler((call) async {
      if (call.method != 'turn' || !_keys || _turning) return;
      sync(interaction: true);
      if (!_keys) return;
      await _runTurn(
        () => widget.onVolumeTurn?.call(call.arguments == true),
        '音量键翻页失败',
      );
    });
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (readerRecoveryDiagnosticsEnabled) {
          for (final timer in _recoveryChecks) {
            timer.cancel();
          }
          _recoveryChecks.clear();
          if (state == AppLifecycleState.inactive && foreground) {
            _backgroundAnchor = ref
                .read(readerSessionProvider(widget.bookId))
                .value
                ?.currentAnchor;
          }
          if (state == AppLifecycleState.resumed) {
            ReaderRecoveryDiagnostics.resume();
            for (final seconds in [2, 10]) {
              _recoveryChecks.add(
                Timer(Duration(seconds: seconds), () {
                  _recovery('afterResume${seconds}s');
                  ReaderRecoveryDiagnostics.nativeSnapshot(
                    'afterResume${seconds}s',
                  );
                }),
              );
            }
          }
          _recovery('lifecycleBefore.${state.name}');
          ReaderRecoveryDiagnostics.nativeSnapshot('lifecycle.${state.name}');
        }
        foreground = state == AppLifecycleState.resumed;
        // 解锁或从桌面回来时重新应用阅读设置，不能依赖系统保留隐藏状态。
        if (foreground) _bars = null;
        sync();
        _recovery('lifecycleAfter.${state.name}');
      },
    );
    // WebView 的实际就绪不一定引发 Flutter 重建；只检查状态，不累计时长。
    readiness = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => sync(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    currentRoute = ModalRoute.isCurrentOf(context) ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) sync();
    });
  }

  bool get _readingUncovered {
    final reader = ref.read(readerProvider);
    return !ref.read(readerSourceChangeProvider(widget.bookId)) &&
        currentRoute &&
        widget.ready() &&
        !reader.controlsVisible &&
        reader.panel == ReaderPanel.none &&
        reader.note == null &&
        reader.selection == null;
  }

  bool get _readingVisible => foreground && _readingUncovered;

  // 桌面点击、滚轮和按键都由系统送到当前窗口；Flutter 的焦点状态可能迟到。
  // 统计和 Android 音量键仍使用前台状态，桌面主动操作只检查正文是否可用。
  bool get _desktopInputEnabled => _readingUncovered && !window.exiting.value;

  Map<String, Object?> _wheelState() {
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    final reader = ref.read(readerProvider);
    return {
      ...?widget.wheelReadyDetails?.call(),
      'exiting': window.exiting.value,
      'routeCurrent': currentRoute,
      'sourceChanged': ref.read(readerSourceChangeProvider(widget.bookId)),
      'controls': reader.controlsVisible,
      'panel': reader.panel.name,
      'selection': reader.selection != null,
      'note': reader.note != null,
      'turning': _turning,
      'inputAllowed': _desktopInputEnabled,
      'format': session?.book.format.name,
      'chapter': session?.chapterIndex,
      'page': session?.pageIndex,
      'anchorPresent': session?.currentAnchor != null,
    };
  }

  Future<void> _runTurn(
    Future<void>? Function() action,
    String operation,
  ) async {
    _turning = true;
    try {
      await action();
    } catch (error, stack) {
      if (ReaderTurnStateDiagnostics.tracingWheel) {
        ReaderTurnStateDiagnostics.record('wheel.failed', {
          'errorType': error.runtimeType.toString(),
        });
      }
      AppErrors.report(error, stack, operation: operation, notify: mounted);
      if (mounted) ref.read(readerProvider.notifier).showNotice('翻页失败，请重试');
    } finally {
      _turning = false;
    }
  }

  void _desktopMove(Future<void>? Function() action) {
    if (_turning || !_desktopInputEnabled) {
      if (ReaderTurnStateDiagnostics.tracingWheel) {
        ReaderTurnStateDiagnostics.record('wheel.rejected', {
          'blockReason': _turning ? 'turnInProgress' : 'inputDisabled',
        });
      }
      return;
    }
    sync(interaction: true);
    final turn = _runTurn(action, '桌面翻页失败');
    if (ReaderTurnStateDiagnostics.tracingWheel) {
      unawaited(
        turn.whenComplete(
          () => ReaderTurnStateDiagnostics.record('wheel.finished'),
        ),
      );
    }
  }

  void sync({bool interaction = false}) {
    if (!mounted) return;
    final reader = ref.read(readerProvider);
    final auto = ref.read(automaticReadingProvider(widget.bookId));
    if (!_loggedReady && widget.ready()) {
      _loggedReady = true;
      traceTurn('load first-readable us=${_opening.elapsedMicroseconds}');
    }
    final visible = _readingVisible;
    final controls = ref.read(readingControlsProvider).value;
    // 锁屏、切后台和阅读内弹层都保留系统栏设置。若失去前台时显示系统栏，
    // 回来再隐藏，正文会按临时高度重排，页首反复取整就会退到前一页。
    // 真正退出阅读时才恢复系统栏；计时和音量键仍只在正文前台生效。
    final bars = (controls?.statusBar ?? true, controls?.navigationBar ?? true);
    if (_bars != bars) {
      _recovery('applySystemBars');
      _bars = bars;
      unawaited(window.systemBars(status: bars.$1, navigation: bars.$2));
    }
    // 常亮属于整个前台阅读页，不能跟随统计的“正文无遮挡”条件。
    // 调整面板、选文或等待重排时同样需要保持亮屏。
    final readingRoute =
        currentRoute ||
        reader.panelCovered ||
        reader.panel == ReaderPanel.search;
    final awake =
        foreground &&
        readingRoute &&
        !window.exiting.value &&
        controls?.keepAwake == true;
    final keys =
        visible && controls?.volumeKeys == true && widget.onVolumeTurn != null;
    if (awake != _awake) {
      _awake = awake;
      unawaited(window.keepAwake(awakeOwner, awake));
    }
    if (keys != _keys) {
      _keys = keys;
      unawaited(window.volumeKeys(keys));
    }
    service.setVisual(
      widget.bookId,
      visible: visible,
      automatic: auto.running || auto.preparing,
      advancing: auto.advancing,
      interaction: interaction,
    );
    final error = service.saveError;
    if (error != null && !identical(error, shownError)) {
      shownError = error;
      ref.read(readerProvider.notifier).showNotice('阅读统计暂未保存，正在重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (readerRecoveryDiagnosticsEnabled) {
      ref.listen(readerSessionProvider(widget.bookId), (previous, next) {
        final before = previous?.value, after = next.value;
        final a = before?.currentAnchor, b = after?.currentAnchor;
        if (before?.chapterIndex != after?.chapterIndex ||
            before?.pageIndex != after?.pageIndex ||
            before?.pageCount != after?.pageCount ||
            before?.layout?.identity != after?.layout?.identity ||
            before?.viewportSignature != after?.viewportSignature ||
            before?.originalFraction != after?.originalFraction ||
            (a == null) != (b == null) ||
            (a != null && b != null && !a.samePosition(b))) {
          _recovery('sessionChanged');
        }
      });
    }
    ref.watch(readingControlsProvider);
    ref.listen(readerProvider, (_, _) => sync());
    ref.listen(automaticReadingProvider(widget.bookId), (_, _) => sync());
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        _recovery('pointerDown');
        sync(interaction: true);
      },
      onPointerMove: (_) => sync(interaction: true),
      onPointerUp: (_) {
        _recovery('pointerUp');
        sync(interaction: true);
      },
      child: switch (widget.desktopScrolling) {
        final scrolling? => DesktopReadingInput(
          scrolling: scrolling,
          readWheelModifier: Platform.isWindows
              ? readWindowsWheelModifier
              : null,
          enabled: () => _desktopInputEnabled,
          onTurn: (forward) =>
              _desktopMove(() => widget.onVolumeTurn?.call(forward)),
          onScroll: (delta) =>
              _desktopMove(() => widget.onDesktopScroll?.call(delta)),
          onZoom: (delta, position) {
            if (_turning || widget.onDesktopZoom == null) return;
            sync(interaction: true);
            widget.onDesktopZoom!(delta, position);
          },
          child: widget.child,
        ),
        null => widget.child,
      },
    );
  }

  @override
  void dispose() {
    if (readerTurnStateDiagnosticsEnabled) {
      ReaderTurnStateDiagnostics.detach(this);
    }
    for (final timer in _recoveryChecks) {
      timer.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    ReaderRecoveryDiagnostics.detach(this);
    readiness.cancel();
    lifecycle.dispose();
    ReadingWindow.channel.setMethodCallHandler(null);
    unawaited(window.volumeKeys(false));
    unawaited(window.systemBars(status: true, navigation: true));
    unawaited(window.keepAwake(awakeOwner, false));
    // 正常退出已显式等待保存；意外移除仅同步结算，交给现有心跳提交。
    service.detachVisual();
    super.dispose();
  }
}
