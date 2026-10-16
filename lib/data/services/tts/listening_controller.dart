import 'dart:async';

import '../../../domain/models/locator.dart';
import '../../../domain/models/speech_unit.dart';
import '../../../domain/models/tts_state.dart';
import '../../../domain/services/listening_source.dart';
import '../../../domain/services/listening_service.dart';
import '../../../domain/services/tts_engine.dart';
import 'listening_event_parser.dart';
import 'listening_position_writer.dart';
import 'listening_page_splitter.dart';
import '../../../domain/repositories/tts_settings_repository.dart';
import 'listening_settings.dart';
import '../../../domain/services/listening_deadline.dart';
import 'listening_sleep_timer.dart';
import 'listening_audio_focus.dart';
import 'tracked_listening_source.dart';

part 'listening_event_handler.dart';
part 'listening_window_preparation.dart';
part 'listening_sleep_policy.dart';

/// 应用级播放调度。只等待提交请求，绝不等待一句读完才接收控制命令。
class ListeningController implements ListeningService {
  ListeningController({
    required this.engine,
    required ListeningSource source,
    this.eventTimeout,
    this.positions,
    this.audioFocus,
    this.onContentChanged,
    this.pauseAutomaticReading,
    TtsSettingsRepository? settingsRepository,
    ListeningDeadline? deadline,
  }) : source = TrackedListeningSource(source),
       settings = ListeningSettings(
         engine,
         settingsRepository,
         audioFocus: audioFocus,
       ) {
    if (deadline != null) {
      _sleep = ListeningSleepTimer(
        deadline,
        (remaining) => _emit(snapshot.copyWith(remaining: remaining)),
        () => unawaited(stop()),
        (error) => unawaited(_finish(TtsStatus.error, error: '定时失败：$error')),
      );
    }
    _events = engine.events.listen(_onEvent);
    positions?.onError = (error) {
      unawaited(_finish(TtsStatus.error, error: '听书位置保存失败：$error'));
    };
  }

  final TtsEngine engine;
  final TrackedListeningSource source;
  final void Function(String)? onContentChanged;

  /// 所有播放入口在发声前等待视觉自动阅读撤图并保存位置。
  final Future<void> Function()? pauseAutomaticReading;
  final _changingBooks = <String>{};
  final ListeningPositionWriter? positions;
  final ListeningAudioFocus? audioFocus;
  final ListeningSettings settings;
  ListeningSleepTimer? _sleep;
  String? _sleepChapter;
  Future<List<OfflineVoice>>? _preparingVoices;
  int _voiceDetection = 0;

  @override
  Future<List<OfflineVoice>> prepareVoices() =>
      _preparingVoices ??= _prepareVoices().whenComplete(() {
        _preparingVoices = null;
      });

  Future<List<OfflineVoice>> _prepareVoices() async {
    if (snapshot.hasSession && settings.voices.isNotEmpty) {
      return settings.voices;
    }
    final epoch = _epoch;
    await _command(epoch, () async {
      try {
        await settings.prepare();
        if (!_current(epoch)) return;
        _emit(
          snapshot.copyWith(
            voice: settings.voice,
            speed: settings.value.speed,
            error: null,
          ),
        );
      } catch (error) {
        if (!_current(epoch)) return;
        _emit(snapshot.copyWith(voice: null, error: '$error'));
      }
    });
    return settings.voices;
  }

  @override
  Future<List<TtsEngineInfo>> listEngines() => settings.listEngines();

  @override
  Future<List<OfflineVoice>> detectVoices(String? enginePackage) async {
    final detection = ++_voiceDetection;
    // 先让旧结果失效，再从独立平台队列唤醒旧连接；否则新选择会被
    // _engineTail 和原生串行队列挡住，连续切换时逐次等待完整超时。
    _invalidate();
    await engine.cancelInitialization();
    if (_disposed || detection != _voiceDetection) return const [];
    await pause();
    if (_disposed || detection != _voiceDetection) return const [];
    final epoch = _invalidate();
    var voices = <OfflineVoice>[];
    await _command(epoch, () async {
      voices = await settings.detectVoices(
        enginePackage,
        canRestore: () => _current(epoch) && detection == _voiceDetection,
      );
    });
    return voices;
  }

  @override
  Future<void> previewVoice(OfflineVoice voice) async {
    settings.validatePreview(voice);
    await pause();
    final epoch = _invalidate();
    final id = 'preview:$epoch:${++_attempt}';
    _emit(snapshot.copyWith(previewing: true));
    // 先挂错误监听；引擎可能在 speak 返回前报告失败。
    final preview = settings.beginPreview(id);
    try {
      await _command(epoch, () async {
        await settings.startPreview(voice, id, canSpeak: () => _current(epoch));
      });
      await preview.completed;
    } finally {
      await preview.close();
      if (_current(epoch)) _emit(snapshot.copyWith(previewing: false));
      await _command(epoch, settings.finishPreview);
    }
  }

  /// 删除/重解析持有此租约期间，通知与界面都不能重新启动这本书。
  Future<void Function()> suspendBookContent(String bookId) async {
    if (!_changingBooks.add(bookId)) throw StateError('这本书正在处理，请稍后再试');
    try {
      if (snapshot.bookId == bookId) {
        await stop();
        await positions?.flush();
        if (snapshot.status == TtsStatus.error) {
          throw StateError(snapshot.error!);
        }
      }
      await source.drain(bookId);
    } catch (_) {
      _changingBooks.remove(bookId);
      rethrow;
    }
    return () {
      onContentChanged?.call(bookId);
      _changingBooks.remove(bookId);
    };
  }

  Future<void> flushPosition() async {
    try {
      await positions?.flush();
    } catch (error) {
      await _finish(TtsStatus.error, error: '听书位置保存失败：$error');
    }
  }

  /// 测试可缩短超时；正式阈值按长度和语速留出合成与朗读余量。
  final Duration? eventTimeout;
  Timer? _watchdog;
  final _states = StreamController<ListeningState>.broadcast();
  late final StreamSubscription<TtsEngineEvent> _events;
  ListeningState _snapshot = const ListeningState();
  @override
  ListeningState get snapshot => _snapshot;
  @override
  Stream<ListeningState> get state => _states.stream;
  ListeningBook? _book;
  SpeechUnit? _unit;
  @override
  void setPageBoundaries(Object owner, List<Locator> boundaries) {
    // 保留显示器契约；页界只用于视觉跟随，朗读不在这里拆句。
  }

  final List<SpeechUnit> _window = [];
  Locator? _next;
  bool _nextSentenceStart = false;
  String? _activeId;
  int _epoch = 0;
  int _attempt = 0;
  int _maxLength = 200;
  int _resumeOffset = 0;
  int _sentOffset = 0;
  bool _started = false;
  String? _targetChapter;
  int _targetDirection = 1;
  Future<void> _engineTail = Future.value();
  Future<void>? _cleanup;
  bool _disposed = false;
  int? _cleanupEpoch;

  void _emit(ListeningState value) {
    if (_disposed) return;
    final locator = value.confirmedLocator;
    if (locator != null &&
        snapshot.confirmedLocator?.samePosition(locator) != true) {
      positions?.update(locator);
    }
    _snapshot = value;
    _states.add(value);
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;

  int _invalidate() {
    _watchdog?.cancel();
    _activeId = null;
    return ++_epoch;
  }

  /// 序列化短平台操作，避免旧 stop 迟到后停掉新 speak。
  Future<void> _command(int epoch, Future<void> Function() action) {
    final result = _engineTail.then((_) async {
      if (_current(epoch)) await action();
    });
    _engineTail = result.catchError((Object _) {});
    return result;
  }

  Future<void> _guard(int epoch, Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!_current(epoch)) return;
      await _finish(TtsStatus.error, error: '听书失败：$error');
    }
  }

  @override
  Future<void> start(
    String bookId,
    Locator locator, {
    bool sentenceStart = true,
  }) => _start(bookId, locator, sentenceStart: sentenceStart);

  Future<void> _start(
    String bookId,
    Locator locator, {
    bool playImmediately = true,
    bool sentenceStart = true,
  }) async {
    await _readingHandoff;
    if (_disposed || _changingBooks.contains(bookId)) return;
    if (_book != null &&
        snapshot.status == TtsStatus.paused &&
        snapshot.bookId == bookId &&
        snapshot.resumeLocator?.samePosition(locator) == true) {
      return play();
    }
    final epoch = _invalidate();
    _unit = null;
    _targetChapter = null;
    _window.clear();
    _next = null;
    final oldBook = _book;
    _book = null;
    final keepTimer = snapshot.bookId == bookId && !snapshot.sleepPolicy.isOff;
    if (!keepTimer) {
      _sleepChapter = null;
      _sleepPending = false;
    }
    final cancelTimer = keepTimer ? null : _sleep?.setMinutes(null);
    _emit(
      ListeningState(
        status: TtsStatus.preparing,
        desiredPlaying: playImmediately,
        // 音色和语速属于应用配置；准备新会话时保留已确认值，避免面板闪回空值。
        voice: snapshot.voice,
        speed: snapshot.speed,
        bookId: bookId,
        resumeLocator: locator,
        sessionEpoch: epoch,
        sleepPolicy: keepTimer ? snapshot.sleepPolicy : const SleepPolicy.off(),
        remaining: keepTimer ? snapshot.remaining : null,
      ),
    );
    await _guard(epoch, () async {
      await cancelTimer;
      await pauseAutomaticReading?.call();
      if (!_current(epoch)) return;
      await oldBook?.close();
      await _command(epoch, () async {
        await engine.stop();
        await positions?.begin(bookId);
        if (!_current(epoch)) return;
        await settings.prepare();
        if (!_current(epoch)) return;
        _maxLength = (await engine.maxSpeechInputLength()).clamp(1, 200);
        if (!_current(epoch)) return;
        _emit(
          snapshot.copyWith(voice: settings.voice, speed: settings.value.speed),
        );
      });
      if (!_current(epoch)) return;
      final book = await source.open(bookId, locator.contentVersion);
      if (!_current(epoch)) {
        await book.close();
        return;
      }
      _book = book;
      _emit(snapshot.copyWith(bookTitle: book.title));
      _next = locator;
      _nextSentenceStart = sentenceStart;
      await _advance(epoch);
    });
  }

  bool _sleepPending = false;
  Future<void>? _windowLoad;
  int? _windowEpoch;

  Future<void> _advance(int epoch) async {
    await _fillWindow(epoch);
    if (!_current(epoch)) return;
    // B3 已按目录锚点切开 unit；检查逻辑章而不是正文文件或章名。
    if (_sleepChapter != null &&
        (_window.isEmpty || _window.first.logicalChapterId != _sleepChapter)) {
      await stop();
      return;
    }
    if (_window.isEmpty) {
      await _finish(TtsStatus.completed);
      return;
    }
    // 换页只影响画面跟随，不能把一句话切成两次合成，制造句中停顿。
    _unit = _window.removeAt(0);
    _resumeOffset = 0;
    final unit = _unit!;
    final chapter = _book!.chapters.firstWhere(
      (c) => c.id == unit.logicalChapterId,
    );
    _emit(
      snapshot.copyWith(
        logicalChapterId: chapter.id,
        chapterTitle: chapter.title,
        resumeLocator: unit.startLocator,
      ),
    );
    if (snapshot.desiredPlaying) {
      await _submit(epoch);
    } else {
      _emit(
        snapshot.copyWith(
          status: TtsStatus.paused,
          currentSentence: unit.sentenceText,
          activeUnit: unit,
        ),
      );
    }
  }

  @override
  Future<void> pause() async {
    if (snapshot.previewing) {
      final epoch = _invalidate();
      _emit(snapshot.copyWith(previewing: false));
      await _command(epoch, settings.finishPreview);
      return;
    }
    if (!snapshot.desiredPlaying) return;
    final epoch = _invalidate();
    _emit(
      snapshot.copyWith(
        status: TtsStatus.paused,
        desiredPlaying: false,
        sessionEpoch: epoch,
      ),
    );
    await _guard(
      epoch,
      () => _command(epoch, () async {
        await engine.stop();
        await positions?.flush();
        await audioFocus?.release();
      }),
    );
  }

  Future<void>? _readingHandoff;
  @override
  Future<void> takeOverReading(String bookId) {
    if (snapshot.bookId != bookId) return Future.value();
    return _readingHandoff ??= _handOffReading().whenComplete(() {
      _readingHandoff = null;
    });
  }

  Future<void> _handOffReading() async {
    if (!snapshot.followReading) return;
    await pause();
    final epoch = _invalidate();
    // 先撤销跟随资格，再等待写盘，迟到的正文回报不得拉回旧句。
    _emit(
      snapshot.copyWith(
        followReading: false,
        activeUnit: null,
        currentSentence: '',
        sessionEpoch: epoch,
      ),
    );
    await _command(epoch, () async {
      await positions?.release();
      final book = _book;
      _book = null;
      _unit = null;
      _window.clear();
      _next = null;
      _targetChapter = null;
      await book?.close();
    });
    if (_sleepChapter != null) {
      _sleepChapter = null;
      _emit(
        snapshot.copyWith(
          sleepPolicy: const SleepPolicy.off(),
          notice: '手动阅读，已取消读完本章定时',
        ),
      );
    }
  }

  @override
  void updateReadingPosition(Locator locator) {
    if (snapshot.bookId != locator.bookId || snapshot.followReading) return;
    _emit(snapshot.copyWith(resumeLocator: locator, confirmedLocator: locator));
  }

  @override
  Future<void> play() async {
    await _readingHandoff;
    if (_disposed) return;
    if (snapshot.desiredPlaying || snapshot.resumeLocator == null) return;
    if (_book == null) {
      return start(snapshot.bookId, snapshot.resumeLocator!);
    }
    final epoch = _invalidate();
    _emit(
      snapshot.copyWith(
        status: TtsStatus.preparing,
        desiredPlaying: true,
        sessionEpoch: epoch,
        error: null,
      ),
    );
    await _guard(epoch, () async {
      await pauseAutomaticReading?.call();
      if (!_current(epoch)) return;
      await _command(epoch, engine.stop);
      if (!_current(epoch)) return;
      if (_targetChapter != null) {
        await _loadTarget(epoch);
      } else if (_unit != null) {
        await _submit(epoch);
      } else {
        await _advance(epoch);
      }
    });
  }

  @override
  Future<void> previousChapter() => _jump(-1);
  @override
  Future<void> nextChapter() => _jump(1);

  Future<void> _jump(int direction) async {
    await _readingHandoff;
    if (_book == null && snapshot.hasSession && !snapshot.followReading) {
      // 手动接管已关闭旧正文；以新的阅读落点准备目录，全程保持暂停。
      final epoch = _epoch + 1;
      await _start(
        snapshot.bookId,
        snapshot.resumeLocator!,
        playImmediately: false,
      );
      if (!_current(epoch) || snapshot.status != TtsStatus.paused) return;
    }
    final book = _book;
    if (book == null) return;
    final entries = book.chapters;
    final current = entries.indexWhere(
      (c) => c.id == (_targetChapter ?? snapshot.logicalChapterId),
    );
    if (current < 0) return;
    final target = current + direction;
    if (target < 0 || target >= entries.length) {
      _emit(snapshot.copyWith(error: direction < 0 ? '已经是第一章' : '已经是最后一章'));
      return;
    }
    // 必须先记录目标再 await，连续两次下一章才会走两章。
    final cancelledChapterTimer = _sleepChapter != null;
    if (cancelledChapterTimer) {
      _sleepChapter = null;
      _emit(
        snapshot.copyWith(
          sleepPolicy: const SleepPolicy.off(),
          remaining: null,
          notice: '手动换章，已取消读完本章定时',
        ),
      );
    }
    _targetChapter = entries[target].id;
    _targetDirection = direction;
    final epoch = _invalidate();
    _unit = null;
    _window.clear();
    _next = null;
    _emit(
      snapshot.copyWith(
        status: TtsStatus.preparing,
        sessionEpoch: epoch,
        confirmedLocator: null,
        activeUnit: null,
        error: null,
      ),
    );
    await _guard(epoch, () async {
      await _command(epoch, () async {
        await engine.stop();
        await positions?.flush();
      });
      if (_current(epoch)) await _loadTarget(epoch);
    });
  }

  Future<void> _loadTarget(int epoch) async {
    final book = _book!;
    Locator locator;
    SpeechWindow page;
    while (true) {
      final target = _targetChapter!;
      locator = await book.chapterStart(target);
      if (!_current(epoch)) return;
      page = await book.window(
        locator,
        sentenceStart: false,
        maxLength: _maxLength,
      );
      if (!_current(epoch)) return;
      while (page.units.isEmpty && page.next != null) {
        page = await book.window(
          page.next!,
          sentenceStart: false,
          maxLength: _maxLength,
        );
        if (!_current(epoch)) return;
      }
      final entries = book.chapters;
      final index = entries.indexWhere((c) => c.id == target);
      if (_targetDirection < 0 &&
          index > 0 &&
          (page.units.isEmpty || page.units.first.logicalChapterId != target)) {
        // 往前换章遇到图片/空范围，要继续向前找，不能又跳回原来的章。
        _targetChapter = entries[index - 1].id;
        continue;
      }
      break;
    }
    _targetChapter = null;
    _window.addAll(page.units);
    _next = page.next;
    _nextSentenceStart = false;
    // 新目标已准备好才通知阅读页；准备期间不再用上一章的确认位置跳回去。
    _emit(snapshot.copyWith(resumeLocator: locator, confirmedLocator: locator));
    await _advance(epoch);
  }

  @override
  Future<void> stop() {
    if (snapshot.status == TtsStatus.idle) return Future.value();
    if (_cleanupEpoch == _epoch) return _cleanup ?? Future.value();
    if (snapshot.status == TtsStatus.stopped) return _cleanup ?? Future.value();
    return _finish(TtsStatus.stopped);
  }

  Future<void> _finish(TtsStatus status, {String? error}) =>
      _cleanup = _cleanUp(status, error: error);

  Future<void> _cleanUp(TtsStatus status, {String? error}) async {
    final epoch = _invalidate();
    _sleepPending = false;
    final cancelTimer = _sleep?.setMinutes(null);
    _sleepChapter = null;
    _cleanupEpoch = epoch;
    _unit = null;
    _targetChapter = null;
    _window.clear();
    _next = null;
    final book = _book;
    _book = null;
    _emit(
      snapshot.copyWith(
        // 自然完成要等最后一个确认点落库，不能让完成事件先于持久化。
        status: status == TtsStatus.completed ? TtsStatus.preparing : status,
        desiredPlaying: false,
        sessionEpoch: epoch,
        currentSentence: '',
        activeUnit: null,
        previewing: false,
        error: error,
        sleepPolicy: const SleepPolicy.off(),
        remaining: null,
      ),
    );
    try {
      await cancelTimer;
      await _command(epoch, () async {
        await engine.stop();
        await audioFocus?.release();
        await positions?.release();
      });
    } catch (failure) {
      if (_current(epoch)) {
        _emit(
          snapshot.copyWith(status: TtsStatus.error, error: '停止听书失败：$failure'),
        );
      }
    } finally {
      await book?.close();
      if (_current(epoch)) {
        _cleanupEpoch = null;
        if (status == TtsStatus.completed &&
            snapshot.status != TtsStatus.error) {
          _emit(snapshot.copyWith(status: TtsStatus.completed));
        }
      }
    }
  }

  Future<void> _submit(int epoch) async {
    // 停止时预设的时长从首次提交朗读开始算，准备正文和选音色不消耗时长。
    if (_sleepPending) {
      _sleepPending = false;
      await _sleep?.setMinutes(snapshot.sleepPolicy.minutes);
    }
    if (await _sleep?.check() == true || !_current(epoch)) return;
    final unit = _unit!;
    final id = '$epoch:${unit.startLocator.chapterId}:${unit.id}:${++_attempt}';
    _activeId = id;
    _started = false;
    _sentOffset = _resumeOffset;
    _emit(
      snapshot.copyWith(
        status: TtsStatus.preparing,
        resumeLocator: listeningPosition(unit, _sentOffset),
      ),
    );
    _watchdog?.cancel();
    _watchdog = Timer(
      eventTimeout ??
          Duration(
            seconds: 30 + (unit.text.length * 2 / snapshot.speed).ceil(),
          ),
      () {
        if (_activeId == id) {
          unawaited(_finish(TtsStatus.error, error: '语音回调超时，请重试（$id）'));
        }
      },
    );
    await _command(epoch, () async {
      await audioFocus?.acquire();
      // 焦点请求期间可能接到暂停/停止，旧任务不得发声。
      if (!_current(epoch)) return;
      await engine.speak(id, unit.text.substring(_sentOffset));
    });
    // 预取不占平台操作队列，暂停不必等正文读取。
    if (engine is PreparedTtsEngine) {
      await _fillWindow(epoch);
      if (_current(epoch) &&
          _activeId == id &&
          _window.isNotEmpty &&
          (_sleepChapter == null ||
              _window.first.logicalChapterId == _sleepChapter)) {
        await _command(
          epoch,
          () => (engine as PreparedTtsEngine).prepareSpeech(_window.first.text),
        );
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _sleep?.dispose();
    _invalidate();
    await _engineTail;
    await source.close();
    await _events.cancel();
    await audioFocus?.dispose();
    await _book?.close();
    await _states.close();
  }

  @override
  Future<bool> setVoice(OfflineVoice voice) => _changeSettings(voice: voice);
  @override
  Future<void> setRate(double rate) async {
    if (!rate.isFinite) throw ArgumentError.value(rate, 'rate');
    await _changeSettings(rate: (rate.clamp(0.5, 2.0) * 10).round() / 10);
  }

  Future<bool> _changeSettings({OfflineVoice? voice, double? rate}) async {
    final epoch = _invalidate();
    final playing = snapshot.desiredPlaying;
    _emit(
      snapshot.copyWith(
        status: playing ? TtsStatus.preparing : snapshot.status,
        sessionEpoch: epoch,
        error: null,
      ),
    );
    var applied = false;
    String? failure;
    try {
      await _command(epoch, () async {
        await engine.stop();
        await positions?.flush();
        try {
          await settings.change(selected: voice, rate: rate);
          applied = true;
        } catch (error) {
          failure = '听书设置未更改：$error';
        }
        // 即使用户在配置期间暂停，已成功落库的设置也要如实显示。
        _emit(
          snapshot.copyWith(
            voice: settings.voice,
            speed: settings.value.speed,
            error: failure,
          ),
        );
      });
      if (!_current(epoch)) return applied;
      if (failure != null) {
        if (settings.voice == null) {
          await _finish(TtsStatus.error, error: failure);
          return false;
        }
      }
      if (playing) {
        if (_book == null) {
          await start(snapshot.bookId, snapshot.resumeLocator!);
        } else if (_targetChapter != null) {
          await _loadTarget(epoch);
        } else if (_unit != null) {
          await _submit(epoch);
        } else {
          await _advance(epoch);
        }
      }
    } catch (error) {
      if (_current(epoch)) await _finish(TtsStatus.error, error: '$error');
      return false;
    }
    return applied;
  }

  @override
  Future<void> setSleepPolicy(
    SleepPolicy policy, {
    String? bookId,
    bool restartTimer = false,
  }) => _setSleepPolicy(policy, bookId: bookId, restartTimer: restartTimer);
}
