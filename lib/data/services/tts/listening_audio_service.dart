/// 启动听书的后台媒体服务（离线听书实现计划 第 9 节）。
///
/// `AudioService.init` 每个进程只能调一次：重复调用会重建 Handler，后台正在读的
/// 内容就断了。而启动门（`StartupGate`）在失败时会重试、Activity 重建也可能再走一遍
/// 启动流程，所以这里用模块级 memo 保证「只初始化一次」，
/// 并且只在**真的失败**时才清掉 memo 允许重试。
library;

import 'package:audio_service/audio_service.dart';

import 'listening_audio_handler.dart';

/// 已经发起过的初始化。成功后就一直复用这个 handler。
Future<ListeningAudioHandler>? _pending;

/// 拿到应用级听书 Handler；第一次调用时初始化后台媒体服务。
Future<ListeningAudioHandler> startListeningAudioService() {
  final pending = _pending;
  if (pending != null) return pending;

  final future = _initialize();
  _pending = future;
  // 失败时清掉 memo，让下一次重试能真正重新初始化；
  // 这里吞掉错误只是为了避免「没人处理的异常」，调用方拿到的仍是原始的 future。
  future.then<void>((_) {}, onError: (Object _) {
    if (identical(_pending, future)) _pending = null;
  });
  return future;
}

Future<ListeningAudioHandler> _initialize() {
  return AudioService.init<ListeningAudioHandler>(
    builder: ListeningAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.gtreader.listening',
      androidNotificationChannelName: '听书播放',
      androidNotificationChannelDescription: '显示正在朗读的章节，并提供播放控制',
      // 点通知回到应用，不新建页面
      androidNotificationClickStartsActivity: true,
      // 暂停时退出前台：长时间暂停不该一直挂着无声的前台服务（实现计划 第 9 节）。
      // 代价是暂停后从后台恢复播放需要系统允许，这一条要真机验证（A3b）。
      androidStopForegroundOnPause: true,
    ),
  );
}
