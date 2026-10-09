/// 听书的后台媒体服务 Handler（离线听书实现计划 第 9 节）。
///
/// 分工：audio_service 提供前台服务、MediaSession 与通知；**业务队列不在这里**，
/// 这里只做两件事：
/// 1. 把媒体通知/锁屏/耳机按钮的命令转出来（[commands]）；
/// 2. 把业务层的最新状态翻译成系统看到的 [mediaItem] 与 [playbackState]。
///
/// 这样系统永远只有一个播放循环在跑（Dart 侧的听书控制器），
/// 不会出现「通知以为在播、其实没声音」或反过来。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../../../domain/models/tts_state.dart';
import '../../../domain/services/listening_service.dart';
import '../../../domain/repositories/reading_position_repository.dart';
import 'listening_controller.dart';

/// 来自媒体通知、锁屏、耳机线控的命令。
enum ListeningCommand { play, pause, stop, previousChapter, nextChapter }

/// 媒体会话的控制端。由 `bootstrap` 在启动时创建一次并保活，
/// 不挂靠任何页面（实现计划 第 9 节：不创建依赖活跃阅读页的 background task）。
class ListeningAudioHandler extends BaseAudioHandler {
  ListeningAudioHandler();

  ListeningController? _controller;
  bool _restoreSuspended = false;

  /// 快照和换库期间忽略通知/耳机命令，避免停止后又被旧通知重新播放。
  Future<void Function()> suspendForRestore() async {
    _restoreSuspended = true;
    try { await _controller?.stop(); }
    catch (_) { _restoreSuspended = false; rethrow; }
    return () => _restoreSuspended = false;
  }
  ListeningService? get service => _controller;
  Future<void> flushPosition() async => _controller?.flushPosition();

  Future<void Function()> suspendBookContent(String bookId) async =>
      await _controller?.suspendBookContent(bookId) ?? () {};

  /// 阅读页首次显示前取实时位置，不依赖最多一秒前的合并写盘记录。
  Future<ReadingPosition?> prepareReader(String bookId) async {
    final controller = _controller;
    if (controller == null) return null;
    if (controller.snapshot.bookId != bookId) {
      await controller.pause();
      await controller.positions?.flush();
      return null;
    }
    await controller.positions?.flush();
    final state = controller.snapshot;
    final locator = state.status == TtsStatus.paused
        ? state.resumeLocator
        : state.confirmedLocator;
    if (!state.hasSession || locator == null) return null;
    return controller.positions?.resolve(locator);
  }

  StreamSubscription<ListeningState>? _snapshots;

  /// Handler 持有控制器；Provider 或阅读页面释放不影响播放。
  void attachController(ListeningController controller) {
    if (_controller != null) throw StateError('听书控制器只能绑定一次');
    _controller = controller;
    _snapshots = controller.state.listen((state) {
      if (state.previewing) {
        publishState(bookId: state.bookId, bookTitle: '音色试听',
            chapterTitle: '试听结束后正文保持暂停', playing: false, preparing: true);
      } else if (!state.hasSession || state.status == TtsStatus.error) {
        clearPlayback();
      } else {
        publishState(
          bookId: state.bookId,
          chapterId: state.logicalChapterId,
          bookTitle: state.bookTitle,
          chapterTitle: state.chapterTitle,
          playing: state.isPlaying,
          preparing:
              state.status == TtsStatus.preparing && state.desiredPlaying,
        );
      }
    });
  }

  /// 先断开通知命令，再等待旧控制器及原生引擎关闭；Handler 本身继续复用。
  Future<void> detachController() async {
    final previous = _controller;
    _controller = null;
    await _snapshots?.cancel();
    _snapshots = null;
    if (previous != null) {
      await previous.dispose();
      await previous.positions?.flush();
      await previous.engine.dispose();
    }
    clearPlayback();
  }

  /// 真正停止媒体状态；不能把 stop 再派发回控制器形成循环。
  void clearPlayback() {
    _lastPlaying = false;
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
    mediaItem.add(null);
  }

  final StreamController<ListeningCommand> _commands =
      StreamController<ListeningCommand>.broadcast();

  /// 命令流。业务层（听书控制器）订阅它，不在这里直接操作 TTS。
  Stream<ListeningCommand> get commands => _commands.stream;

  /// 上一次播报出去的媒体快照，用于判断状态是否真的变了（避免通知反复重建）。
  bool _lastPlaying = false;

  /// 把业务层当前状态同步给系统。
  ///
  /// [duration] 故意不给：引擎不提供整章时长，填一个假的会让锁屏出现可拖动的
  /// 假时间轴（实现计划 第 9 节）。
  void publishState({
    String bookId = 'listening',
    String chapterId = '',
    required String bookTitle,
    required String chapterTitle,
    required bool playing,
    bool completed = false,
    bool preparing = false,
  }) {
    final item = MediaItem(
      id: bookId,
      title: chapterTitle.isEmpty ? bookTitle : chapterTitle,
      album: bookTitle,
      extras: {'bookId': bookId, 'chapterId': chapterId},
      // 通知里不显示时长，也不提供拖动
      playable: false,
    );
    final old = mediaItem.value;
    if (old?.id != item.id ||
        old?.title != item.title ||
        old?.album != item.album ||
        old?.extras?['chapterId'] != chapterId) {
      mediaItem.add(item);
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          // 同一个按钮位按当前状态在播放/暂停之间切换
          playing || preparing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        // 紧凑区（Android 通知的折叠按钮）只放上一章、播放/暂停、下一章；
        // 停止放在展开区，系统排布因版本而异，但停止在应用里始终可点。
        androidCompactActionIndices: const [0, 1, 2],
        processingState: completed
            ? AudioProcessingState.completed
            : preparing
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        // 下一段准备时保持服务，实际发声状态仍由控制器 started 确认。
        playing: playing || preparing,
      ),
    );
    _lastPlaying = playing;
  }

  /// 当前是否处于播放态（通知图标与实际是否出声都以这个为准）。
  bool get isPlaying => _lastPlaying;

  // 系统调用等待业务命令完成，异常由调用者接收，不能仅投递流后就报成功。
  Future<void> _run(ListeningCommand command) async {
    if (_restoreSuspended) return;
    _commands.add(command);
    final controller = _controller;
    if (controller == null) return; // 保留 A 阶段原型的命令观察接口。
    await switch (command) {
      ListeningCommand.play => controller.play(),
      ListeningCommand.pause => controller.pause(),
      ListeningCommand.stop => controller.stop(),
      ListeningCommand.previousChapter => controller.previousChapter(),
      ListeningCommand.nextChapter => controller.nextChapter(),
    };
  }

  @override
  Future<void> play() => _run(ListeningCommand.play);
  @override
  Future<void> pause() => _run(ListeningCommand.pause);
  @override
  Future<void> stop() => _run(ListeningCommand.stop);
  @override
  Future<void> skipToNext() => _run(ListeningCommand.nextChapter);
  @override
  Future<void> skipToPrevious() => _run(ListeningCommand.previousChapter);

  /// 应用退出时释放；界面进出不调用。
  Future<void> dispose() async {
    await _snapshots?.cancel();
    await _controller?.dispose();
    clearPlayback();
    await _commands.close();
  }
}
