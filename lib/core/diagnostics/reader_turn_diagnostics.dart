import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const readerTurnDiagnosticsEnabled = bool.fromEnvironment(
  'GT_TRACE_READER_TURN',
);

/// 各种排版与翻页的手动复现日志。只观察既有事件，停手后才取网页数组和写盘。
abstract final class ReaderTurnDiagnostics {
  static const channel = OptionalMethodChannel(
    'gtreader/reader_turn_diagnostics',
  );
  static final _owners = <Object>{};
  static final _traces = <ReaderTurnTrace>[];
  static Timer? _timer;
  static Future<void>? _flushing;
  static var _sequence = 0;
  static bool _timingsInstalled = false;
  static String? _nativeFailure;

  static ReaderTurnTrace? get active => !readerTurnDiagnosticsEnabled
      ? null
      : _traces.reversed.where((t) => t.endUs == null).firstOrNull;

  /// 子阅读器先收到命中事件，公共外层随后补齐设置；同一指针只建一次记录。
  static ReaderTurnTrace? pointerDown(
    PointerDownEvent event,
    Map<String, Object?> context, [
    int? viewId,
  ]) {
    if (!readerTurnDiagnosticsEnabled || _owners.isEmpty) return null;
    final trace = forPointer(event.pointer) ?? begin(context, viewId);
    if (trace != null && viewId != null && trace.nativeViewId != viewId) {
      trace.nativeViewId = viewId;
      unawaited(native('bind', {'id': trace.id, 'viewId': viewId}));
    }
    trace?.mergeContext(context);
    trace?.input(event, 'down');
    return trace;
  }

  static ReaderTurnTrace? forPointer(int pointer) =>
      !readerTurnDiagnosticsEnabled
      ? null
      : _traces.reversed.where((t) => t.pointer == pointer).firstOrNull;

  static void arm(Object owner, bool active) {
    if (!readerTurnDiagnosticsEnabled) return;
    final changed = active ? _owners.add(owner) : _owners.remove(owner);
    if (!changed) return;
    unawaited(native('arm', _owners.isNotEmpty));
    if (!_timingsInstalled && _owners.isNotEmpty) {
      _timingsInstalled = true;
      WidgetsBinding.instance.addTimingsCallback(_frames);
    }
    if (_owners.isEmpty && _timingsInstalled) {
      WidgetsBinding.instance.removeTimingsCallback(_frames);
      _timingsInstalled = false;
    }
  }

  static ReaderTurnTrace? begin(Map<String, Object?> context, int? viewId) {
    if (!readerTurnDiagnosticsEnabled) return null;
    // 连续操作也有内存上限；溢出时保留已采数值并明确标记缺少网页快照。
    if (_traces.length == 16) {
      final oldest = _traces.removeAt(0);
      oldest.finish('bufferLimit');
      unawaited(_save(oldest, browser: false));
    }
    final trace = ReaderTurnTrace(
      '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}',
      context,
    );
    trace.nativeViewId = viewId;
    _traces.add(trace);
    unawaited(
      native('begin', {
        'id': trace.id,
        'viewId': viewId,
        'dartUs': trace.beginUs,
        'wallUs': trace.wallUs,
      }),
    );
    activity();
    return trace;
  }

  static void activity() {
    if (!readerTurnDiagnosticsEnabled || _traces.isEmpty) return;
    // 手指按住时不反复分配Timer；松手后的低频事件才重新开始安静窗口。
    _timer?.cancel();
    _timer = null;
    if (!_traces.any((trace) => !trace.released && trace.endUs == null)) {
      _timer = Timer(const Duration(milliseconds: 1200), _idle);
    }
  }

  static void _idle() {
    _timer = null;
    if (_traces.isEmpty) return;
    if (_traces.any((trace) => !trace.released && trace.endUs == null)) {
      _timer = Timer(const Duration(milliseconds: 1200), _idle);
      return;
    }
    for (final trace in _traces.where((trace) => trace.endUs == null)) {
      if (!trace.operationActive) {
        trace.finish('pointerOnly');
      } else if (!trace.waitingSaved) {
        trace.waitingSaved = true;
        trace.event('waitingAfterRelease');
        unawaited(_save(trace, browser: false));
      }
    }
    unawaited(flush());
  }

  static void _frames(List<FrameTiming> frames) {
    for (final frame in frames) {
      for (final trace in _traces) {
        trace.frame(frame);
      }
    }
  }

  static Future<Object?> native(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<Object?>(method, arguments);
    } catch (error) {
      // 日志通路的失败不进入翻页等待链，也不递归弹出异常提示。
      _nativeFailure = '$method:${error.runtimeType}';
      return null;
    }
  }

  static Future<void> flush({bool force = false}) async {
    if (!readerTurnDiagnosticsEnabled) return;
    if (_flushing case final pending?) {
      await pending;
      if (force) await flush(force: true);
      return;
    }
    final ready = _traces
        .where((trace) => force || trace.endUs != null)
        .toList();
    _flushing = _flush(ready).whenComplete(() => _flushing = null);
    await _flushing;
  }

  static Future<void> _flush(List<ReaderTurnTrace> ready) async {
    for (final trace in ready) {
      await _save(trace);
      _traces.remove(trace);
    }
  }

  static Future<void> _save(
    ReaderTurnTrace trace, {
    bool browser = true,
  }) async {
    final web = <String, Object?>{};
    if (browser) {
      for (final source in trace.browserSources.entries.toList()) {
        try {
          final value = await source.value().timeout(
            const Duration(seconds: 2),
          );
          web[source.key] = value is String ? jsonDecode(value) : value;
        } catch (error) {
          web[source.key] = {'unavailable': error.runtimeType.toString()};
        }
      }
    }
    await native(
      'append',
      jsonEncode({
        ...trace.snapshot(),
        'browser': web,
        'browserSkipped': !browser,
        'nativeFailure': _nativeFailure,
      }),
    );
  }
}

/// 每个输入的数组有独立上限；原始时间与写盘时间分开，不保存正文或书籍身份。
class ReaderTurnTrace {
  ReaderTurnTrace(this.id, Map<String, Object?> details)
    : context = {
        for (final key in _contextKeys)
          if (details.containsKey(key)) key: details[key],
      };

  static const _contextKeys = [
    'layout',
    'effect',
    'bookEdges',
    'fontFamily',
    'fontSize',
    'fontWeight',
    'lineHeight',
    'paragraphGapEm',
    'useOriginalFont',
    'orientation',
    'dpr',
    'refreshRate',
    'width',
    'height',
    'pageWidth',
    'pageHeight',
    'hostWidth',
    'chapter',
    'page',
    'pages',
    'edge',
    'busy',
    'ignored',
    'landing',
    'handover',
    'hostReady',
    'format',
    'landscape',
    'spreadEnabled',
    'spreadActive',
    'controls',
    'panel',
  ];
  static const limit = 3072;
  final String id;
  final Map<String, Object?> context;
  final beginUs = Timeline.now;
  final wallUs = DateTime.now().microsecondsSinceEpoch;
  final inputs = <List<Object>>[],
      events = <List<Object>>[],
      commands = <List<Object>>[],
      frames = <List<int>>[];
  final dropped = <String, int>{};
  int? endUs;
  int? pointer;
  bool released = false, operationActive = false, waitingSaved = false;
  String status = 'active';
  final browserSources = <String, Future<Object?> Function()>{};
  var _commandSequence = 0;
  PointerEvent? _lastInput;
  String? _lastPhase;
  int? nativeViewId;

  void mergeContext(Map<String, Object?> details) {
    for (final key in _contextKeys) {
      if (details.containsKey(key)) context[key] = details[key];
    }
  }

  void _add<T>(String name, List<T> target, T row) {
    if (target.length < limit) {
      target.add(row);
    } else {
      dropped[name] = (dropped[name] ?? 0) + 1;
    }
  }

  void input(PointerEvent event, String phase) {
    // Listener沿命中路径收到的是坐标变换副本，不能只按对象身份去重。
    final previous = _lastInput;
    if (previous != null &&
        _lastPhase == phase &&
        previous.pointer == event.pointer &&
        previous.timeStamp == event.timeStamp &&
        previous.position == event.position &&
        previous.delta == event.delta &&
        previous.synthesized == event.synthesized) {
      return;
    }
    _lastInput = event;
    _lastPhase = phase;
    pointer ??= event.pointer;
    if (event.pointer != pointer) return;
    _add('inputs', inputs, <Object>[
      Timeline.now,
      event.timeStamp.inMicroseconds,
      phase,
      event.pointer,
      event.position.dx,
      event.position.dy,
      event.delta.dx,
      event.delta.dy,
      event.synthesized,
    ]);
    if (phase == 'up' || phase == 'cancel') released = true;
    ReaderTurnDiagnostics.activity();
  }

  void event(String name, [List<Object> details = const []]) {
    _add('events', events, <Object>[Timeline.now, name, ...details]);
    ReaderTurnDiagnostics.activity();
  }

  int commandBegin(String name, {int hostToken = 0}) {
    final sequence = ++_commandSequence;
    // 只留方法名，绝不把含正文、标注或路径的完整脚本写入日志。
    _add('commands', commands, <Object>[
      sequence,
      Timeline.now,
      0,
      name.split('(').first,
      hostToken,
    ]);
    ReaderTurnDiagnostics.activity();
    return sequence;
  }

  void commandEnd(int sequence) {
    if (sequence <= commands.length) commands[sequence - 1][2] = Timeline.now;
    ReaderTurnDiagnostics.activity();
  }

  void frame(FrameTiming frame) {
    final vsync = frame.timestampInMicroseconds(FramePhase.vsyncStart);
    if (vsync < beginUs || endUs != null && vsync > endUs! + 300000) return;
    _add('frames', frames, [
      vsync,
      frame.timestampInMicroseconds(FramePhase.buildStart),
      frame.timestampInMicroseconds(FramePhase.rasterStart),
      frame.timestampInMicroseconds(FramePhase.rasterFinish),
      frame.buildDuration.inMicroseconds,
      frame.rasterDuration.inMicroseconds,
      frame.totalSpan.inMicroseconds,
    ]);
  }

  void finish(String reason) {
    if (endUs != null) return;
    endUs = Timeline.now;
    status = reason;
    event('complete', [reason]);
    unawaited(
      ReaderTurnDiagnostics.native('finish', {'id': id, 'status': reason}),
    );
  }

  Map<String, Object?> snapshot() => {
    'kind': 'readerTurn',
    'schema': 1,
    'id': id,
    'context': context,
    'beginUs': beginUs,
    'wallUs': wallUs,
    'endUs': endUs,
    'status': status,
    'writtenWallUs': DateTime.now().microsecondsSinceEpoch,
    'columns': {
      'inputs': [
        'receivedUs',
        'eventUs',
        'phase',
        'pointer',
        'x',
        'y',
        'dx',
        'dy',
        'synthesized',
      ],
      'events': ['atUs', 'name', 'numericDetailsOrStatus'],
      'commands': ['sequence', 'beginUs', 'endUs', 'method', 'hostToken'],
      'frames': [
        'vsyncUs',
        'buildStartUs',
        'rasterStartUs',
        'rasterFinishUs',
        'buildUs',
        'rasterUs',
        'spanUs',
      ],
    },
    'inputs': inputs,
    'events': events,
    'commands': commands,
    'frames': frames,
    'dropped': dropped,
    'timingNote': 'Flutter/WebView/Android draw callbacks are separate from actual screen presentation.',
  };
}
