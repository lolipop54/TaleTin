import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/tts_state.dart';
import '../view_models/reader_session_view_model.dart';
import 'original_layout_controller.dart';
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
    } else if (speech.bookId == bookId &&
        speech.hasSession &&
        speech.followReading) {
      await service.play();
    } else {
      await ref.read(readerSessionProvider(bookId).future);
      if (!ref.mounted) return;
      try {
        final session = ref.read(readerSessionProvider(bookId)).value!;
        final reader = ref.read(readerSessionProvider(bookId).notifier);
        // 新开始和手动阅读后再开始都取可见页首。原书的续读/切换锚点
        // 可能位于页中，不能拿它或文字比例代替实际分页后的第一个字。
        var anchor = reader.listeningStartAnchor;
        if (reader.layoutMode.isOriginal && !session.scrolling) {
          final prepare = ref
              .read(originalLayoutProvider(bookId))
              .value
              ?.visiblePageAnchor;
          if (prepare == null) throw StateError('书页尚未就绪，请稍后再试');
          anchor = await prepare();
        }
        if (!ref.mounted) return;
        if (anchor != null) {
          await service.start(bookId, anchor, sentenceStart: false);
        }
      } catch (error) {
        if (ref.mounted) ref.read(readerProvider.notifier).showNotice('$error');
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
