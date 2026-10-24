import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/reading_settings.dart';

final globalSettingsProvider =
    AsyncNotifierProvider<GlobalSettingsNotifier, GlobalReadingPreferences>(
      GlobalSettingsNotifier.new,
    );

/// 所有全局排版入口共用这条写入队列，逐次读取最新值，只改本次选择的字段。
class GlobalSettingsNotifier extends AsyncNotifier<GlobalReadingPreferences> {
  Future<void> _writing = Future.value();
  Future<void> flush() => _writing;
  @override
  Future<GlobalReadingPreferences> build() async {
    final repo = ref.watch(readingSettingsRepositoryProvider);
    // 首页只需要真实保存值；设备字体由字体预览/正文页面按需准备。
    final global = await repo.loadGlobal() ?? kBuiltinReadingSettings;
    return GlobalReadingPreferences(
      typography: global,
      themeId: await repo.loadThemeId(),
    );
  }

  Future<void> change(ReadingSettings Function(ReadingSettings) update) =>
      _enqueue(() async {
        final repo = ref.read(readingSettingsRepositoryProvider);
        final next = update(await repo.loadGlobal() ?? kBuiltinReadingSettings);
        await repo.saveGlobal(next);
        if (ref.mounted) {
          state = AsyncData(
            GlobalReadingPreferences(
              typography: next,
              themeId: await repo.loadThemeId(),
            ),
          );
        }
      });

  Future<void> theme(String themeId) => _enqueue(() async {
    final repo = ref.read(readingSettingsRepositoryProvider);
    await repo.saveThemeId(themeId);
    if (ref.mounted) {
      state = AsyncData(
        GlobalReadingPreferences(
          typography: state.requireValue.typography,
          themeId: themeId,
        ),
      );
    }
  });

  /// 与普通设置修改串行，避免删除字体时把刚调整的字号或字重覆盖掉。
  Future<void> resetFontFamily(String family) => _enqueue(() async {
    final repo = ref.read(readingSettingsRepositoryProvider);
    await repo.resetFontFamily(family);
    final current = state.requireValue;
    if (ref.mounted && current.typography.fontFamily == family) {
      state = AsyncData(
        GlobalReadingPreferences(
          typography: current.typography.copyWith(fontFamily: 'sans-serif'),
          themeId: current.themeId,
        ),
      );
    }
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _writing.then((_) => action());
    // 单次失败交给界面提示，之后的修改仍然能够重试。
    _writing = operation.catchError((Object _) {});
    return operation;
  }
}
