import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次系统音频打断在听书里应该执行的动作。
enum ListeningInterruption {
  /// 通知、导航等短暂提示音：停住发声，等系统交还焦点后自动继续。
  ///
  /// 系统把这种抢占标成 duck（可以压低），含义就是「我一定会很快还给你」。
  hold,

  /// 系统确认焦点已经归还：可以继续，是否真的继续由控制器再判断。
  resume,

  /// 来电、别的音乐视频等抢占：按普通暂停处理，不自动恢复。
  pause,
}

/// 唯一焦点持有者。中断结束只恢复系统资格，不替用户继续朗读。
///
/// 例外是「可被压低」的短暂提示音（通知、导航）：系统明确要求应用自己处理这类抢占，
/// 这里只按住发声，焦点归还后再继续，不改变用户的播放意图。
class ListeningAudioFocus {
  ListeningAudioFocus({required this.activate, required this.ready});

  final Future<bool> Function(bool) activate;
  final Future<void> Function() ready;
  bool _held = false;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// 把一次中断事件翻译成听书动作。
  ///
  /// - 开始 + duck：可压低（提示音类）→ 按住；
  /// - 开始 + pause/unknown：来电或其他应用长期占用 → 暂停；
  /// - 结束：焦点已归还 → 交给控制器决定能否继续。
  static ListeningInterruption interruptionOf(AudioInterruptionEvent event) {
    if (!event.begin) return ListeningInterruption.resume;
    return event.type == AudioInterruptionType.duck
        ? ListeningInterruption.hold
        : ListeningInterruption.pause;
  }

  static Future<ListeningAudioFocus> create({
    required Future<void> Function() pause,
    required Future<void> Function() hold,
    required Future<void> Function() resume,
  }) async {
    final session = await AudioSession.instance;
    // speech() 默认声明「被压低就暂停」，系统于是把通知音也当成暂停事件。
    // 改成 false 之后，可压低（通知/导航）与需要暂停（来电/音乐）才能区分开；
    // 注意这两个动作仍然都走我们自己的判断，系统不会自动压低朗读音量。
    await session.configure(
      const AudioSessionConfiguration.speech().copyWith(
        androidWillPauseWhenDucked: false,
      ),
    );
    final focus = ListeningAudioFocus(
      activate: session.setActive,
      ready: () async {
        // 等真实前台服务就绪，不能靠固定延时猜测 Android 15 的焦点资格。
        const channel = MethodChannel('gtreader/listening_media');
        await channel.invokeMethod<void>('awaitForeground');
      },
    );
    final callbacks = {
      ListeningInterruption.pause: pause,
      ListeningInterruption.hold: hold,
      ListeningInterruption.resume: resume,
    };
    focus._subscriptions.add(
      session.interruptionEventStream.listen((event) {
        // 真机排查用：一眼能看出这次通知被系统判成 duck 还是临时中断；
        // 只有事件类型，不含书名、正文和章节。
        debugPrint('[听书] 音频焦点${event.begin ? '开始' : '结束'}：${event.type.name}');
        final action = interruptionOf(event);
        unawaited(callbacks[action]!());
      }),
    );
    focus._subscriptions.add(
      session.becomingNoisyEventStream.listen((_) {
        // 耳机拔出：用户需要自己决定，按普通暂停处理。
        unawaited(pause());
      }),
    );
    return focus;
  }

  Future<void> acquire() async {
    if (_held) return;
    await ready();
    if (!await activate(true)) throw StateError('未获得音频焦点，请稍后重试');
    _held = true;
  }

  Future<void> release() async {
    if (!_held) return;
    await activate(false);
    _held = false;
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await release();
  }
}
