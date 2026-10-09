import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/channels/reading_fonts.dart';
import '../../ui/features/settings/view_models/global_reading_settings.dart';

final selectedFontLoaderProvider = Provider<Future<String?> Function(String?)>(
  (_) => ReadingFonts.loadSelected,
);

final systemFontFamilyProvider = FutureProvider<String?>(
  (_) => ReadingFonts.loadSystem(),
);

/// 只读取全局设置；原书字体属于具体 EPUB，不能用作应用界面字体。
final appFontFamilyProvider = FutureProvider<String?>((ref) async {
  final preferences = await ref.watch(globalSettingsProvider.future);
  final settings = preferences.typography;
  if (settings.fontOnlyInReader ||
      settings.fontFamily == null ||
      settings.fontFamily == 'sans-serif' ||
      (settings.layoutMode.isOriginal && settings.useOriginalFont)) {
    return ref.watch(systemFontFamilyProvider.future);
  }
  return ref.read(selectedFontLoaderProvider)(settings.fontFamily);
});

/// 排版设置页只展示当前字体；进入字体选择页才加载完整名单和预览。
final currentTypographyFontsProvider = FutureProvider<Map<String, String?>>((ref) async {
  final settings = (await ref.watch(globalSettingsProvider.future)).typography;
  if (!(settings.layoutMode.isOriginal && settings.useOriginalFont)) {
    await ref.read(selectedFontLoaderProvider)(settings.fontFamily);
  }
  return ReadingFonts.loadedNames;
});
