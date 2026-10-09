import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/tts_state.dart';
import '../view_models/reader_session_view_model.dart';
import 'reader_view_model.dart';

/// 面板只准备选项，播放状态始终来自应用级服务。
final listeningVoicesProvider = FutureProvider.autoDispose<List<OfflineVoice>>(
  (ref) => ref.watch(listeningServiceProvider).prepareVoices(),
);

final listeningPanelProvider = Provider.autoDispose
    .family<ListeningPanelCommands, String>((ref, bookId) {
      return ListeningPanelCommands(ref, bookId);
    });

class ListeningPanelCommands {
  ListeningPanelCommands(this.ref, this.bookId);
  final Ref ref;
  final String bookId;

  Future<void> toggle() async {
    final service = ref.read(listeningServiceProvider);
    // 新开或继续听书都先撤半页扫描，再保存实际正文位置。
    if (service.snapshot.bookId != bookId || !service.snapshot.desiredPlaying) {
      await ref.read(automaticReadingTasksProvider).stopAll();
      if (!ref.mounted) return;
    }
    final speech = service.snapshot;
    if (speech.bookId == bookId && speech.desiredPlaying) {
      await service.pause();
    } else if (speech.bookId == bookId && speech.hasSession) {
      await service.play();
    } else {
      await ref.read(readerSessionProvider(bookId).future);
      if (!ref.mounted) return;
      // 停止已经结束会话：重新开始读当前显示页的页首，而不是最后一句。
      // 暂停后的“继续”仍走上面的 play，保留句内续播能力。
      final restartPage =
          speech.bookId == bookId && speech.status == TtsStatus.stopped;
      final anchor = restartPage
          ? ref.read(readerSessionProvider(bookId)).value?.currentAnchor
          : speech.bookId == bookId && speech.followReading
          ? speech.resumeLocator ??
                ref
                    .read(readerSessionProvider(bookId).notifier)
                    .listeningStartAnchor
          : ref
                .read(readerSessionProvider(bookId).notifier)
                .listeningStartAnchor;
      if (anchor != null) {
        await service.start(bookId, anchor, sentenceStart: !restartPage);
      }
    }
  }

  Future<void> rate(double value) =>
      ref.read(listeningServiceProvider).setRate(value);

  Future<void> sleep(SleepPolicy policy) async {
    try {
      await ref.read(listeningServiceProvider).setSleepPolicy(policy);
    } catch (error) {
      if (ref.mounted) ref.read(readerProvider.notifier).showNotice('$error');
    }
  }

  Future<void> stop() => ref.read(listeningServiceProvider).stop();
  Future<void> chapter(int delta) async {
    final service = ref.read(listeningServiceProvider);
    final feedback = ref.read(readerProvider.notifier);
    await (delta < 0 ? service.previousChapter() : service.nextChapter());
    final message = service.snapshot.error ?? service.snapshot.notice;
    if (message != null) feedback.showNotice(message);
  }
}
