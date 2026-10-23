import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/reading_statistics.dart';
import '../repositories/reading_statistics_repository.dart';
import 'reading_clock.dart';
import 'reading_segment_slicer.dart';
import 'reading_statistics_writer.dart';
import 'listening_service.dart';
import '../models/tts_state.dart';

/// 应用级唯一采集器。所有模式先在同一采样点结算，再共同切换墙钟映射。
class ReadingStatisticsService {
  ReadingStatisticsService(
    ReadingStatisticsRepository repository, {
    ReadingClock? clock,
    this.onError,
  }) : clock = clock ?? SystemReadingClock(),
       writer = ReadingStatisticsWriter(repository) {
    _at = this.clock.sample();
  }
  final ReadingClock clock;
  final ReadingStatisticsWriter writer;
  final void Function(Object, StackTrace)? onError;
  final runId = const Uuid().v4();
  final _active = <ReadingMode, _TrackedReading>{};
  // 一次进入书籍共用一个会话；面板、后台和超时只暂停有效片段。
  _TrackedReading? _visualVisit;
  late ClockSample _at;
  Timer? _timer;
  StreamSubscription<ListeningState>? _listening;
  String? _book;
  bool _visible = false, _automatic = false, _advancing = false;
  int _lastInteraction = 0;
  int _idleMinutes = 5;
  bool _resetting = false;
  Completer<void>? _resetDone;
  bool _closed = false;
  String? _audioBook;
  bool _audioSpeaking = false, _audioConnected = false;
  int get idleMinutes => _idleMinutes;
  bool get visualActive => _active.containsKey(ReadingMode.visual);
  Object? get saveError => writer.lastError;

  Future<void> initialize() async {
    await writer.repository.closeInterrupted();
    startHeartbeat();
  }

  void startHeartbeat() {
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => _saveSoon());
  }

  void attachListening(ListeningService listening) {
    if (_listening != null) throw StateError('统计已绑定听书服务');
    void update(ListeningState state) => setAudio(
      state.bookId,
      speaking: state.status == TtsStatus.playing,
      connected:
          state.desiredPlaying &&
          (state.status == TtsStatus.playing ||
              state.status == TtsStatus.preparing),
    );
    _listening = listening.state.listen(update);
    update(listening.snapshot);
  }

  void setIdleMinutes(int minutes) {
    if (_closed) return;
    if (![2, 5, 10].contains(minutes)) throw ArgumentError.value(minutes);
    // 重置期间允许保存偏好，但等事务完成后再按新阈值开始采集。
    if (_resetting) {
      _idleMinutes = minutes;
      return;
    }
    _capture(clock.sample());
    _idleMinutes = minutes;
    _reconcileVisual();
    _saveSoon();
  }

  void setVisual(
    String? bookId, {
    required bool visible,
    bool automatic = false,
    bool advancing = false,
    bool interaction = false,
  }) {
    if (_closed) return;
    if (_resetting) {
      _book = bookId;
      _visible = visible;
      _automatic = automatic;
      _advancing = advancing;
      return;
    }
    if (interaction &&
        _book == bookId &&
        _visible == visible &&
        _automatic == automatic &&
        _advancing == advancing &&
        visualActive) {
      final now = clock.sample();
      if (now.tickMs < _lastInteraction + _idleMinutes * 60000) {
        _lastInteraction = now.tickMs;
        return; // 连续拖动只刷新活动，不为每个像素创建片段或写数据库。
      }
    }
    if (!interaction &&
        _book == bookId &&
        _visible == visible &&
        _automatic == automatic &&
        _advancing == advancing) {
      return;
    }
    _capture(clock.sample());
    if (interaction || (_book != bookId) || (!_visible && visible)) {
      _lastInteraction = _at.tickMs;
    }
    _book = bookId;
    _visible = visible;
    _automatic = automatic;
    _advancing = advancing;
    _reconcileVisual();
    _saveSoon();
  }

  void _reconcileVisual() {
    final valid =
        _visible &&
        _book != null &&
        (_automatic
            ? _advancing
            : _at.tickMs < _lastInteraction + _idleMinutes * 60000);
    final current = _visualVisit;
    if (current != null && current.session.bookId != _book) {
      _end(ReadingMode.visual, _book == null ? 'readerLeft' : 'bookChanged');
    }
    if (valid) {
      _begin(ReadingMode.visual, _book!);
    } else {
      _active.remove(ReadingMode.visual);
    }
  }

  /// preparing 可以保留同一次听书会话，但等待下一句不生成有效片段。
  void setAudio(
    String? bookId, {
    required bool speaking,
    required bool connected,
  }) {
    if (_closed) return;
    _audioBook = bookId;
    _audioSpeaking = speaking;
    _audioConnected = connected;
    if (_resetting) return;
    final current = _active[ReadingMode.audio];
    if (current?.session.bookId == bookId &&
        current?.speaking == speaking &&
        connected) {
      return;
    }
    _capture(clock.sample());
    if (!connected || (current != null && current.session.bookId != bookId)) {
      _end(ReadingMode.audio, 'playbackEnded');
    }
    if (connected &&
        bookId != null &&
        (speaking || _active.containsKey(ReadingMode.audio))) {
      _begin(ReadingMode.audio, bookId);
      _active[ReadingMode.audio]!.speaking = speaking;
    }
    _saveSoon();
  }

  void _begin(ReadingMode mode, String bookId) {
    if (_active.containsKey(mode)) return;
    if (mode == ReadingMode.visual && _visualVisit != null) {
      _active[mode] = _visualVisit!;
      return;
    }
    final session = ReadingSession(
      id: const Uuid().v4(),
      bookId: bookId,
      mode: mode,
      startedUtc: _at.utc,
    );
    _active[mode] = _TrackedReading(session);
    if (mode == ReadingMode.visual) _visualVisit = _active[mode];
    writer.sessions.add(session);
  }

  void _end(ReadingMode mode, String reason) {
    final tracked =
        _active.remove(mode) ??
        (mode == ReadingMode.visual ? _visualVisit : null);
    if (mode == ReadingMode.visual) _visualVisit = null;
    if (tracked == null) return;
    final s = tracked.session;
    writer.sessions.add(
      ReadingSession(
        id: s.id,
        bookId: s.bookId,
        mode: s.mode,
        startedUtc: s.startedUtc,
        endedUtc: tracked.lastEnd ?? s.startedUtc,
        endReason: reason,
      ),
    );
  }

  void _capture(ClockSample now) {
    for (final tracked in _active.values.toList()) {
      final s = tracked.session;
      if (s.mode == ReadingMode.audio && !tracked.speaking) continue;
      var end = now.tickMs;
      final deadline = _lastInteraction + _idleMinutes * 60000;
      if (s.mode == ReadingMode.visual && !_automatic && end > deadline) {
        end = deadline;
      }
      final pieces = sliceReading(
        session: s,
        runId: runId,
        start: _at,
        endTickMs: end,
        newId: const Uuid().v4,
      ).toList();
      writer.segments.addAll(pieces);
      if (pieces.isNotEmpty) tracked.lastEnd = pieces.last.endUtc;
      if (s.mode == ReadingMode.visual &&
          !_automatic &&
          now.tickMs >= deadline) {
        _active.remove(ReadingMode.visual);
      }
    }
    _at = now;
  }

  Future<void> flush() async {
    // 用户可在重置尚未结束时离开设置页；恢复快照必须等清理事务完成。
    await _resetDone?.future;
    if (_closed) return writer.flush();
    _capture(clock.sample());
    return writer.flush();
  }

  void _saveSoon() {
    unawaited(
      flush().catchError((Object e, StackTrace stack) {
        onError?.call(e, stack);
      }),
    );
  }

  /// 等旧片段写完再清除；期间只保留最新活动状态，不能把旧队列写回新统计。
  Future<void> reset(Future<void> Function() clear) async {
    if (_closed) return;
    if (_resetting) throw StateError('正在重置');
    _capture(clock.sample());
    _resetting = true;
    final done = _resetDone = Completer<void>();
    for (final mode in ReadingMode.values) {
      _end(mode, 'statisticsReset');
    }
    try {
      await writer.flush();
      await clear();
    } finally {
      _at = clock.sample();
      _lastInteraction = _at.tickMs;
      _resetting = false;
      if (!_closed) {
        _reconcileVisual();
        setAudio(
          _audioBook,
          speaking: _audioSpeaking,
          connected: _audioConnected,
        );
      }
      _resetDone = null;
      done.complete();
    }
  }

  Future<void> leaveVisual() async {
    setVisual(null, visible: false);
    await flush();
  }

  void detachVisual() {
    if (_closed) return;
    _capture(clock.sample());
    _end(ReadingMode.visual, 'detached');
    _book = null;
    _visible = false;
  }

  /// 恢复交接先结算并等待落盘，之后晚到的页面/听书事件不再创建旧会话。
  Future<void> shutdown() async {
    await _resetDone?.future;
    if (!_closed) {
      _capture(clock.sample());
      _closed = true;
      _timer?.cancel();
      await _listening?.cancel();
      for (final mode in ReadingMode.values) {
        _end(mode, 'libraryRestore');
      }
    }
    await writer.flush();
  }

  /// dispose 只释放资源；退出/后台须在此前显式结算，异常退出不补时间。
  void dispose() {
    _timer?.cancel();
    unawaited(_listening?.cancel());
  }
}

class _TrackedReading {
  _TrackedReading(this.session);
  final ReadingSession session;
  DateTime? lastEnd;
  bool speaking = true;
}
