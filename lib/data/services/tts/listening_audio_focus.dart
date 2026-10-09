import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';

/// 唯一焦点持有者。中断结束只恢复系统资格，不替用户继续朗读。
class ListeningAudioFocus {
  ListeningAudioFocus({required this.activate, required this.ready});

  final Future<bool> Function(bool) activate;
  final Future<void> Function() ready;
  bool _held = false;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  static Future<ListeningAudioFocus> create(
    Future<void> Function() pause,
  ) async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    final focus = ListeningAudioFocus(
      activate: session.setActive,
      ready: () async {
        // 等真实前台服务就绪，不能靠固定延时猜测 Android 15 的焦点资格。
        const channel = MethodChannel('gtreader/listening_media');
        await channel.invokeMethod<void>('awaitForeground');
      },
    );
    focus._subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (event.begin) unawaited(pause());
      }),
    );
    focus._subscriptions.add(
      session.becomingNoisyEventStream.listen((_) {
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
