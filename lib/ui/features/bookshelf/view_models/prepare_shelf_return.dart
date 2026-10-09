import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../platform/channels/reading_window.dart';

/// 阅读位置落库后，在阅读页仍遮住书架时取新快照并完成一次构建。
/// 手动订阅保持查询活跃，避免后台书架因路由不可见暂停接收数据库变化。
Future<void> prepareShelfReturn(WidgetRef ref) async {
  final subscription = ref.listenManual(libraryBooksProvider, (_, _) {});
  try {
    // 阅读页仍遮住书架时恢复系统栏，等真实安全区到位后才移除阅读路由。
    await ref.read(readingWindowProvider).prepareExit();
    ref.invalidate(libraryBooksProvider);
    await ref.read(libraryBooksProvider.future);
    await WidgetsBinding.instance.endOfFrame;
  } finally {
    subscription.close();
  }
}
