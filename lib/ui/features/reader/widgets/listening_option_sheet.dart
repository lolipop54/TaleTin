import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../view_models/listening_voice_choices.dart';
import '../../settings/views/listening_voice_view.dart';
import 'reader_option_route.dart';

/// 子面板使用同一个根导航；先收听书，关闭子面板后再恢复听书。
Future<T?> showListeningOption<T>(
  BuildContext context,
  WidgetRef ref,
  WidgetBuilder builder, {
  String? bookId,
  bool shrinkWrap = false,
}) => showReaderOption<T>(context, ref, builder, bookId: bookId, shrinkWrap: shrinkWrap);

Future<void> showListeningVoice(BuildContext context, WidgetRef ref, String bookId) async {
  final container = ProviderScope.containerOf(context);
  // 保持候选数据到弹层关闭，不能在听书面板卸载时释放后重新检测。
  final lease = container.listen(listeningVoiceChoicesProvider, (_, _) {});
  try {
    await container.read(listeningVoiceChoicesProvider.future);
    if (!context.mounted) return;
    await showListeningOption<bool>(
      context,
      ref,
      (_) => const ListeningVoiceView(sheet: true),
      bookId: bookId,
    );
  } finally {
    lease.close();
  }
}
