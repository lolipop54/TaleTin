import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import 'global_reading_settings.dart';

/// 状态信息显示开关（设计文档 2.2 阅读默认值）：全局一份，默认显示。
///
/// 阅读页据此决定要不要画顶部章节信息与底部时间/电量；关掉后正文
/// 可用高度变大，排版会重排并停在原句上（实现计划 S14 验收）。
class StatusInfoVisibleNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() =>
      ref.watch(readingSettingsRepositoryProvider).loadStatusInfoVisible();

  Future<void> toggle() async {
    final current = state.value ?? true;
    await ref
        .read(readingSettingsRepositoryProvider)
        .saveStatusInfoVisible(!current);
    if (ref.mounted) state = AsyncData(!current);
  }
}

final statusInfoVisibleProvider =
    AsyncNotifierProvider<StatusInfoVisibleNotifier, bool>(
  StatusInfoVisibleNotifier.new,
);

/// 排版模式的**全局默认值**（设计文档 2.3：单书覆盖 > 全局默认 > 内置默认）。
///
/// 阅读页面板里改的是「本书覆盖」；这里改的是全局默认值，之后新打开的书
/// 都从它起步。没设置过时按内置默认（简化排版）。
class GlobalLayoutModeNotifier extends AsyncNotifier<ReadingLayoutMode> {
  @override
  Future<ReadingLayoutMode> build() async {
    final global = await ref.watch(globalSettingsProvider.future);
    return global.typography.layoutMode;
  }

  /// 切到另一个模式并写回全局默认值（其余排版项保持原样）
  Future<void> toggle() async {
    final next = (state.value ?? ReadingLayoutMode.simplified).isOriginal
        ? ReadingLayoutMode.simplified
        : ReadingLayoutMode.original;
    await ref.read(globalSettingsProvider.notifier).change((s) => s.copyWith(layoutMode: next));
  }
}

final globalLayoutModeProvider =
    AsyncNotifierProvider<GlobalLayoutModeNotifier, ReadingLayoutMode>(
  GlobalLayoutModeNotifier.new,
);

/// 五种翻页方式共用同一个保存字段，本书有覆盖时仍优先使用本书设置。
class GlobalPageTurnNotifier extends AsyncNotifier<PageTurnEffect> {
  @override
  Future<PageTurnEffect> build() async =>
      (await ref.watch(globalSettingsProvider.future)).typography.pageTurnEffect;

  Future<void> select(PageTurnEffect effect) async {
    await ref.read(globalSettingsProvider.notifier).change((s) => s.copyWith(pageTurnEffect: effect));
  }
}

final globalPageTurnProvider = AsyncNotifierProvider<GlobalPageTurnNotifier,
    PageTurnEffect>(GlobalPageTurnNotifier.new);
