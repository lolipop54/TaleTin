import 'package:taletin/core/diagnostics/app_errors.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../../platform/channels/reading_window.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';
import 'reader_session_view_model.dart';
import 'reader_settings_view_model.dart';
import 'reader_view_model.dart';
import 'listening_view_state.dart';

class AutomaticReadingState {
  const AutomaticReadingState({this.running = false, this.preparing = false,
    this.advancing = false});
  final bool running, preparing;
  /// 显示器实际推进才为真；准备、等待和暂停不能供统计累计时长。
  final bool advancing;
}

/// 两种显示各自按帧推进，控制器只管开始、暂停、听书交接和保存。
class AutomaticScrollBackend {
  const AutomaticScrollBackend({required this.start, required this.stop,
    required this.speed, required this.ready, this.discard, this.retained});
  final Future<void> Function(double) start;
  final Future<void> Function() stop;
  final void Function(double) speed;
  final bool Function() ready;
  final Future<void> Function()? discard;
  final bool Function()? retained;
}

class AutomaticReadingNotifier extends Notifier<AutomaticReadingState> {
  AutomaticReadingNotifier(this.bookId);
  final String bookId;
  final _awakeOwner = Object();
  AutomaticScrollBackend? _backend;
  late ReadingWindow _window;
  int _version = 0;
  Future<void>? _stopping;
  bool _pausedByTap = false;
  bool _foreground = true;
  bool _moving = false;
  bool _hasSession = false;
  bool get hasSession => _hasSession;

  void reportAdvancing(bool value) {
    if (!ref.mounted || (!state.running && !state.preparing)) return;
    _moving = value;
    if (state.running && state.advancing != value) {
      state = AutomaticReadingState(running: true, advancing: value);
    }
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) unawaited(pause(save: false));
  }

  void pointerDown() {
    _pausedByTap = state.running || state.preparing;
    unawaited(pause());
  }

  /// 同一次触摸只暂停；下一次触摸才打开控制栏。
  void centerTap() {
    if (consumePauseTap()) return;
    ref.read(readerProvider.notifier).toggleControls();
  }

  bool consumePauseTap() {
    final paused = _pausedByTap; _pausedByTap = false; return paused;
  }

  /// 手动滚动也要取停下来的真实位置，不能只取上次节流回报。
  Future<void> flushPosition() async {
    await traceReaderWork('reader.exit.auto.previous_stop', () async {
      await _stopping;
    }, {'pending': _stopping != null});
    await traceReaderWork('reader.exit.auto.backend_stop', () async {
      await _backend?.stop();
    }, {'backend': _backend != null});
  }

  @override
  AutomaticReadingState build() {
    _window = ref.read(readingWindowProvider);
    final tasks = ref.read(automaticReadingTasksProvider);
    tasks.attach(this, bookId, discard, changed: () {
      if (ref.mounted) ref.invalidate(readerSessionProvider(bookId));
    });
    ref.listen(listeningViewStateProvider, (_, next) {
      if (next.value?.desiredPlaying == true) unawaited(discard());
    });
    ref.onDispose(() {
      tasks.detach(this);
      ++_version;
      unawaited(_backend?.stop());
      unawaited(_window.keepAwake(_awakeOwner, false));
    });
    return const AutomaticReadingState();
  }

  void attach(AutomaticScrollBackend backend) => _backend = backend;
  bool get canResume => _backend?.retained?.call() ?? false;
  Future<void> discard() async {
    if (!ref.mounted) return;
    // 普通手动翻页没有自动阅读会话时，不向 WebView 发撤图和保存命令。
    if (!state.running && !state.preparing && !_hasSession && !canResume) {
      await _stopping;
      return;
    }
    final save = state.running || state.preparing || _hasSession || canResume;
    _hasSession = false;
    final version = ++_version, previous = _stopping, backend = _backend;
    state = const AutomaticReadingState();
    // 新的开始命令必须等撤图、临时页还原和保存全部完成，不能被迟到的旧撤图取消。
    final task = _stopping = () async {
      await previous;
      if (backend?.discard != null) { await backend!.discard!(); }
      else { await backend?.stop(); }
      if (save) {
        await _window.keepAwake(_awakeOwner, false);
        if (ref.mounted) {
          await ref.read(readerSessionProvider(bookId).notifier).persist();
        }
      }
      if (ref.mounted && version == _version) state = AutomaticReadingState();
    }();
    try { await task; } finally { if (identical(task, _stopping)) _stopping = null; }
  }
  void detach(AutomaticScrollBackend backend) {
    if (!identical(_backend, backend)) return;
    ++_version; _backend = null;
    _hasSession = false;
    final version = _version;
    // 显示器在页面销毁或模式交接时解绑，树更新完后再通知仍在监听的面板。
    scheduleMicrotask(() {
      if (ref.mounted && version == _version && _backend == null) {
        state = const AutomaticReadingState();
      }
    });
    unawaited(_window.keepAwake(_awakeOwner, false));
  }

  Future<void> start() async {
    if (!ref.mounted || !_foreground) return;
    if (!ref.read(automaticReadingTasksProvider).canStart(bookId)) return;
    if (state.running || state.preparing) return;
    final reader = ref.read(readerProvider);
    if (reader.selection != null || reader.note != null ||
        (reader.panel != ReaderPanel.none && reader.panel != ReaderPanel.auto)) {
      ref.read(readerProvider.notifier).showNotice('请先关闭面板或选文，再开始自动阅读');
      return;
    }
    final settings = ref.read(readerSettingsProvider(bookId)).value?.settings;
    final backend = _backend;
    if (settings == null) return;
    final version = ++_version;
    _moving = false;
    state = const AutomaticReadingState(preparing: true);
    try {
      await _stopping;
      if (!ref.mounted || !_foreground || version != _version) return;
      await ref.read(listeningServiceProvider).pause();
      if (!ref.mounted || !_foreground || version != _version) return;
      await ref.read(readerSessionProvider(bookId).notifier).beginAutomaticReading();
      if (!ref.mounted || version != _version) return;
      if (!ref.read(automaticReadingTasksProvider).canStart(bookId)) {
        state = const AutomaticReadingState(); return;
      }
      if (backend == null || !identical(backend, _backend) || !backend.ready()) {
        state = const AutomaticReadingState();
        ref.read(readerProvider.notifier).showNotice('正文正在准备，请稍后开始');
        return;
      }
      ref.read(readerProvider.notifier).closePanel();
      await backend.start(settings.pageTurnEffect == PageTurnEffect.scroll
        ? settings.autoScrollSpeed : settings.autoScanSeconds.toDouble());
      if (!ref.mounted || version != _version) { await backend.stop(); return; }
      _hasSession = true;
      state = AutomaticReadingState(running: true, advancing: _moving);
      await _window.keepAwake(_awakeOwner, settings.autoKeepAwake);
    } on Object catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '启动自动阅读失败');
      if (ref.mounted && version == _version) {
        await backend?.stop();
        await _window.keepAwake(_awakeOwner, false);
        state = const AutomaticReadingState();
        ref.read(readerProvider.notifier).showNotice('自动阅读无法开始：$error');
      }
    }
  }

  Future<void> pause({bool save = true}) async {
    if (!ref.mounted) return;
    if (!state.running && !state.preparing) { await _stopping; return; }
    ++_version;
    final version = _version;
    state = const AutomaticReadingState();
    final backend = _backend;
    final task = _stopping = () async {
      await backend?.stop();
      await _window.keepAwake(_awakeOwner, false);
      if (save && ref.mounted) {
        await ref.read(readerSessionProvider(bookId).notifier).persist();
      }
      if (ref.mounted && version == _version) state = AutomaticReadingState();
    }();
    try { await task; } finally { if (identical(task, _stopping)) _stopping = null; }
  }

  void updateSettings(ReadingSettings settings) {
    if (!state.running) return;
    _backend?.speed(settings.pageTurnEffect == PageTurnEffect.scroll
        ? settings.autoScrollSpeed : settings.autoScanSeconds.toDouble());
    unawaited(_window.keepAwake(_awakeOwner, settings.autoKeepAwake));
  }

  void finish(String notice) {
    if (!ref.mounted) return;
    unawaited(pause());
    ref.read(readerProvider.notifier).showNotice(notice);
  }
}

final automaticReadingProvider = NotifierProvider.family<AutomaticReadingNotifier,
  AutomaticReadingState, String>(AutomaticReadingNotifier.new, isAutoDispose: true);

/// 长帧和等待期间丢掉待走距离，恢复后不会追赶后台经过的时间。
class FrameScrollDistance {
  Duration? _last;
  void reset([Duration? now]) => _last = now;
  double next(Duration now, double speed, {bool waiting = false}) {
    final previous = _last; _last = now;
    if (previous == null || waiting) return 0;
    final micros = (now - previous).inMicroseconds;
    return micros <= 0 || micros > 100000 ? 0 : speed * micros / 1000000;
  }
}
