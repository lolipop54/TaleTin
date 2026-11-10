import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_router.dart';
import '../../../../app/di/statistics_providers.dart';
import '../../../../core/diagnostics/app_errors.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';
import '../../bookshelf/view_models/prepare_shelf_return.dart';
import '../view_models/automatic_reading.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';

/// 正文中的退出入口共用保存顺序；自动阅读暂停后才保存最终位置。
Future<void> saveAndLeaveReader(
  BuildContext context,
  WidgetRef ref,
  String bookId, {
  required String source,
  Map<String, Object?> details = const {},
}) => traceReaderWork('reader.exit.$source', () async {
  await traceReaderWork(
    'reader.exit.$source.auto_pause',
    () => ref.read(automaticReadingProvider(bookId).notifier).pause(),
  );
  await traceReaderWork(
    'reader.exit.$source.settings',
    () => ref.read(readerSettingsProvider(bookId).notifier).pendingWrites,
  );
  await traceReaderWork(
    'reader.exit.$source.position',
    () =>
        ref.read(readerSessionProvider(bookId).notifier).flushPendingPosition(),
  );
  await traceReaderWork(
    'reader.exit.$source.statistics',
    () => ref.read(readingStatisticsServiceProvider).leaveVisual(),
  );
  if (!context.mounted) return;
  await prepareShelfReturnForExit(ref);
  if (context.mounted) leaveReaderPage(context);
}, details);

/// 退出前等书架按新安全区、最新数据准备好；失败也要继续退出。
///
/// 书架自己有错误提示和重试；把阅读页留在“退出中”的屏蔽状态才是真正的卡死。
Future<void> prepareShelfReturnForExit(WidgetRef ref) async {
  try {
    await prepareShelfReturn(ref);
  } catch (error, stack) {
    AppErrors.report(error, stack, operation: '退出阅读时准备书架失败');
  }
}

/// 离开阅读页：有上一页就退回上一页（书架），没有就直接回书架。
///
/// 阅读页通常 push 在书架之上；但通知栏等入口可能让阅读页成为路由栈里唯一
/// 一页，这时 pop 会抛 GoError，页面已进入“退出中”并屏蔽触摸，又退不掉。
void leaveReaderPage(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRoutes.shelf);
  }
}
