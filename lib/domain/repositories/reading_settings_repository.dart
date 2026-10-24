/// 阅读设置仓库（设计文档 2.3 / 7.1）。
///
/// 两级存储：全局阅读默认值，以及每本书的覆盖项。界面读到的是
/// 「内置默认 → 全局 → 单书覆盖」字段级合并后的结果，写的时候只写改动过的那一级：
/// - 面板里直接调参数 → 写全局默认值；
/// - 「单书设置」生效时 → 写本书覆盖项；
/// - 「恢复全局」→ 删除本书覆盖项（不把全局值抄成覆盖值）。
///
/// 只有参与合并的项才进这里；阅读主题虽然不影响分页，但同样支持单书覆盖，
/// 所以也用同一套两级读写（值就是一个主题 id）。
library;

import '../models/reading_settings.dart';

abstract interface class ReadingSettingsRepository {
  /// 全局阅读默认值；从未保存过时返回 null（表示完全用内置默认值）
  Future<ReadingSettings?> loadGlobal();

  /// 覆盖式写入全局阅读默认值
  Future<void> saveGlobal(ReadingSettings settings);

  /// 删除导入字体时，把全局及单书中对此字体的选择改为系统字体，保留其他字段。
  Future<void> resetFontFamily(String family);

  Future<List<String>> loadFontOrder();
  Future<void> saveFontOrder(List<String> families);

  /// 某本书的覆盖项；从未设置过（或已被清空）时返回 null
  Future<ReadingSettingsOverrides?> loadOverrides(String bookId);

  /// 写入某本书的覆盖项；[overrides] 为空表示没有覆盖项，等同于清空
  Future<void> saveOverrides(String bookId, ReadingSettingsOverrides overrides);

  /// 恢复全局：删除本书的全部覆盖项
  Future<void> clearOverrides(String bookId);

  /// 阅读主题 id（`ReadingTheme.name`）；[bookId] 为空表示全局默认，没存过返回 null
  Future<String?> loadThemeId({String? bookId});

  /// 保存阅读主题 id；[themeId] 为空表示删掉该级的选择，回落到下一级
  Future<void> saveThemeId(String? themeId, {String? bookId});

  /// 这本书的窗口亮度覆盖 0–1；没设置过时返回 null（表示跟随系统）
  Future<double?> loadBrightness(String bookId);

  /// 上次自定义窗口亮度；跟随系统时仍保留，旧记录回退到已有亮度。
  Future<double?> loadCustomBrightness(String bookId);

  /// 保存窗口亮度；[value] 为空表示跟随系统，同时保留自定义值
  Future<void> saveBrightness(String bookId, double? value);

  /// 是否显示阅读页的状态信息（顶部章节信息与底部时间电量）；默认显示
  Future<bool> loadStatusInfoVisible();

  Future<void> saveStatusInfoVisible(bool visible);
}
