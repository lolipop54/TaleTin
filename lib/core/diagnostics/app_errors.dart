import 'dart:async';

import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/animation.dart' show TickerCanceled;
import 'package:flutter/services.dart';

import '../../domain/models/backup_operation.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../errors/import_error.dart';
import '../../engine/layout/chapter_layout.dart' show LayoutCancelled;
import '../../engine/layout/scroll_chapter.dart'
    show ScrollPreparationCancelled;
import '../../platform/channels/system_toast.dart';
import 'app_error_store.dart';
import 'reader_turn_diagnostics.dart';
import 'reader_turn_state_diagnostics.dart';

/// 正常撤销任务不作为错误；不能按错误文本猜测取消，以免漏掉真实故障。
bool isExpectedAppCancellation(Object error) =>
    error is BackupCancelled ||
    error is LayoutCancelled ||
    error is ScrollPreparationCancelled ||
    error is TickerCanceled ||
    (error is ContentFailure && error.code == ContentErrorCode.sourceChanged) ||
    (error is ImportFailure && error.code == ImportErrorCode.cancelled);

class AppErrorEvent {
  AppErrorEvent(
    this.id,
    this.operation,
    this.type,
    this.message,
    this.source,
    this.stack,
    this.time,
    this.route,
    this.context,
  );
  final String id, operation, type, message, source, stack, route;
  final DateTime time;
  final Map<String, Object?> context;
  int count = 1;
  late DateTime lastWritten = time;
  DateTime? lastNotified;

  // Android 12 之后系统 Toast 最多两行；完整原因和堆栈留在本地日志。
  String get toast =>
      '$operation [$id]\n$type · ${source.isEmpty ? '详见错误日志' : source.split('/').last}';
  Map<String, Object?> toJson() => {
    'id': id,
    'time': time.toIso8601String(),
    'operation': operation,
    'type': type,
    'message': message,
    'source': source,
    'stack': stack,
    'route': route,
    'context': context,
    'count': count,
  };
}

/// 全局异常与业务已经接住的失败共用入口；只报告，不替调用方回滚或重试。
class AppErrorReporter {
  AppErrorReporter({
    required this.append,
    required this.showToast,
    DateTime Function()? now,
    this.toastInterval = const Duration(seconds: 4),
  }) : now = now ?? DateTime.now;
  final Future<void> Function(Map<String, Object?>) append;
  final Future<void> Function(String) showToast;
  final DateTime Function() now;
  final Duration toastInterval;
  final _recent = <String, AppErrorEvent>{};
  final _queue = Queue<AppErrorEvent>();
  Future<void> _writes = Future.value();
  Timer? _toastTimer;
  DateTime? _lastToastAt;
  bool foreground = true, _writeFailed = false;
  int _overflow = 0;
  String route = '';
  Map<String, Object?> context = {};

  AppErrorEvent? report(
    Object error,
    StackTrace stack, {
    required String operation,
    bool notify = true,
  }) {
    if (isExpectedAppCancellation(error)) return null;
    final text = _limit(error.toString(), 4096);
    final trace = _limit(stack.toString(), 24576);
    final source = _source(trace);
    final type = error is PlatformException
        ? '${error.runtimeType}/${error.code}'
        : error.runtimeType.toString();
    final key = '$type|$text|$source|$route|$context';
    final time = now();
    final old = _recent[key];
    final event =
        old ??
        AppErrorEvent(
          _id(key),
          operation,
          type,
          text,
          source,
          trace,
          time,
          route,
          Map.unmodifiable(context),
        );
    if (old != null) event.count++;
    _recent.remove(key);
    _recent[key] = event;
    if (_recent.length > 64) _recent.remove(_recent.keys.first);
    // 重复布局异常可能逐帧到来：合并重复次数，最多每五秒补记一次。
    if (old == null || time.difference(event.lastWritten).inSeconds >= 5) {
      event.lastWritten = time;
      final json = event.toJson();
      developer.log(
        '[$operation] ${event.id} $type: $text',
        name: 'TaleTin.error',
        error: error,
        stackTrace: stack,
      );
      _writes = _writes.then((_) => append(json)).catchError((Object failure) {
        _writeFailed = true;
        developer.log('错误日志写入失败：$failure', name: 'TaleTin.error');
      });
    }
    if (notify &&
        (event.lastNotified == null ||
            time.difference(event.lastNotified!).inSeconds >= 30)) {
      event.lastNotified = time;
      // 同一故障向多个入口冒泡只提示一次；不同错误依次显示，不互相取消。
      if (_queue.length == 8) {
        _queue.removeLast();
        _overflow++;
      }
      _queue.add(event);
      _drain();
    }
    return event;
  }

  void _drain() {
    if (!foreground || _toastTimer != null || _queue.isEmpty) return;
    final elapsed = _lastToastAt == null
        ? toastInterval
        : now().difference(_lastToastAt!);
    if (elapsed < toastInterval) {
      _toastTimer = Timer(toastInterval - elapsed, () {
        _toastTimer = null;
        _showNext();
      });
      return;
    }
    _showNext();
  }

  void _showNext() {
    if (!foreground || _queue.isEmpty) return;
    final event = _queue.removeFirst();
    _lastToastAt = now();
    final suffix = _overflow == 0 ? '' : '（另有$_overflow条，见日志）';
    _overflow = 0;
    // 提示通道失败不能再次调用本入口，否则会形成递归错误风暴。
    unawaited(
      Future.sync(() => showToast('${event.toast}$suffix'))
          .catchError((Object failure) {
            developer.log('错误提示未显示：$failure', name: 'TaleTin.error');
          }),
    );
    _drain();
  }

  void setForeground(bool value) {
    foreground = value;
    if (value) _drain();
  }

  Future<bool> flush() async {
    await _writes;
    return !_writeFailed;
  }

  void dispose() {
    _toastTimer?.cancel();
    _queue.clear();
  }

  static String _limit(String value, int limit) =>
      value.length <= limit ? value : '${value.substring(0, limit)}…';
  static String _source(String stack) {
    final match = RegExp(r'package:taletin/([^\s)]+)').firstMatch(stack);
    return match?.group(1) ??
        RegExp(r'\(([^()\s]+\.(?:kt|java):\d+)\)')
            .firstMatch(stack)
            ?.group(1) ??
        '';
  }

  static String _id(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return 'E${hash.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }
}

abstract final class AppErrors {
  static final store = AppErrorStore()
    ..environment.addAll({
      'diagnosticBuild': const String.fromEnvironment(
        'GT_DIAGNOSTIC_LABEL',
        defaultValue: 'ordinary',
      ),
      'dart': Platform.version,
    });
  static AppErrorReporter reporter = AppErrorReporter(
    append: (event) =>
        store.append({...event, 'environment': store.environment}),
    showToast: SystemToast.showError,
  );
  static const channel = MethodChannel('gtreader/error_diagnostics');

  static AppErrorEvent? report(
    Object error,
    StackTrace stack, {
    required String operation,
    bool notify = true,
  }) => reporter.report(error, stack, operation: operation, notify: notify);

  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    try {
      store.environment.addAll(
        await channel.invokeMapMethod<String, Object?>('environment') ?? {},
      );
      final previous = await channel.invokeMapMethod<String, Object?>(
        'previousFailure',
      );
      if (previous != null) {
        report(
          PlatformException(
            code: '${previous['type']}',
            message: '退出时间=${previous['time']}；${previous['message']}',
          ),
          StackTrace.fromString('${previous['stack'] ?? ''}'),
          operation: '上次异常退出',
        );
        if (await reporter.flush()) {
          await channel.invokeMethod<void>(
            'acknowledgeFailure',
            previous['time'],
          );
        }
      }
    } catch (error, stack) {
      report(error, stack, operation: '读取设备诊断信息');
    }
  }

  static Future<String> exportText() async {
    await ReaderTurnStateDiagnostics.flush();
    await ReaderTurnDiagnostics.flush(force: true);
    final complete = await reporter.flush();
    final text = await store.exportText();
    var native = '';
    try {
      native =
          await channel
              .invokeMethod<String>('readerExitLog')
              .timeout(const Duration(seconds: 3)) ??
          '';
    } on MissingPluginException {
      // 非 Android 没有原生系统栏记录。
    } catch (error) {
      native = 'Android退出诊断读取失败：${error.runtimeType}\n';
    }
    var slide = '';
    try {
      slide =
          await channel
              .invokeMethod<String>('readerTurnLog')
              .timeout(const Duration(seconds: 3)) ??
          '';
    } on MissingPluginException {
      // 非Android或较旧原生层仍导出其他已取得的日志。
    } catch (error) {
      slide = '翻页诊断读取失败：${error.runtimeType}\n';
    }
    final result = '$text\nAndroid退出阅读诊断\n$native\n翻页诊断\n$slide';
    return complete ? result : '部分错误未能写入本机日志，请同时提供错误Toast截图。\n$result';
  }
}
