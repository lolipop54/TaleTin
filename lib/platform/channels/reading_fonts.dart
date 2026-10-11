import 'dart:io';

import 'package:flutter/services.dart';

import 'preset_fonts.dart';

/// 内置字体与平台确认的设备字体：预览、Flutter 正文和 WebView 共用。
abstract final class ReadingFonts {
  static final _paths = <String, String>{};
  static final _aliases = <String, String>{};
  static final _names = <String, String?>{...PresetFonts.names};
  static Future<Map<String, String?>>? _pending;
  static Future<String?>? _system;

  /// 首页只准备当前系统字体，完整目录仍在字体页打开前准备。
  static Future<String?> loadSystem() =>
      _system ??= _load('system').then((_) => resolve('sans-serif'));

  static Future<Map<String, String?>> load() => _pending ??= () async {
    await loadSystem();
    return {...await _load('list'), ...PresetFonts.names};
  }();

  /// 阅读只准备实际选择的字体；完整名单和所有预览留到字体选择页。
  static Future<String?> loadSelected(String? family) async {
    if (family == null || family == 'sans-serif') return loadSystem();
    // 升级删掉字体，或安装不带内置字体的版本时，先准备真实系统字体。
    // 保留原保存编号，之后换回包含该字体的版本仍能恢复选择。
    if (family.startsWith('gt-preset-') &&
        !PresetFonts.families.containsKey(family)) {
      return loadSystem();
    }
    if (PresetFonts.families.containsKey(family)) {
      PresetFonts.prepare(family);
      return family;
    }
    final selected = resolve(family)!;
    if (!_paths.containsKey(selected)) {
      await _load('selected', family: selected);
    }
    return resolve(family);
  }

  static Map<String, String?> get loadedNames => Map.unmodifiable(_names);

  /// 从系统设置返回后重新读取当前字体；先等旧目录结束，避免旧别名覆盖新结果。
  static Future<void> refreshSystem() async {
    try {
      await _pending;
    } catch (_) {
      /* 旧目录失败不妨碍重新读取。 */
    }
    _pending = null;
    _system = null;
    await loadSystem();
  }

  static Future<Map<String, String?>> _load(
    String method, {
    String? family,
  }) async {
    try {
      final entries =
          await const MethodChannel('gtreader/reading_fonts')
              .invokeListMethod<dynamic>(
                method,
                family == null ? null : {'family': family},
              ) ??
          [];
      final names = <String, String?>{};
      final loading = <Future<void>>[];
      final paths = <String, String>{};
      final aliases = <String, String>{};
      for (final entry in entries) {
        final id = entry['id'] as String;
        final path = entry['path'] as String;
        if (names.containsKey(id)) continue;
        if (!_paths.containsKey(id)) {
          final loader = FontLoader(id)
            ..addFont(
              File(path)
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes)),
            );
          loading.add(loader.load());
        }
        paths[id] = path;
        names[id] = entry['name'] as String;
        for (final alias in entry['aliases'] as List) {
          aliases[alias as String] = id;
        }
      }
      // 独立字体并行加载，全部完成后才发布名单和预览。
      await Future.wait(loading);
      _paths.addAll(paths);
      _aliases.addAll(aliases);
      _names.addAll(names);
      return names;
    } on MissingPluginException {
      return const {};
    }
  }

  /// 兼容旧的 serif/KaiTi 设置；只映射平台已确认的回退关系。
  static String? resolve(String? family) {
    final available =
        family != null &&
            family.startsWith('gt-preset-') &&
            !PresetFonts.families.containsKey(family)
        ? 'sans-serif'
        : family;
    return _aliases[available ?? 'sans-serif'] ?? available;
  }

  static String cssFor(String? family) {
    if (family == null || family.isEmpty) return '';
    final id = resolve(family);
    if (PresetFonts.families.containsKey(id)) return PresetFonts.cssFor(id!);
    return _paths.containsKey(id)
        ? '@font-face{font-family:"$id";src:url("/__gt_fonts/$id");}'
        : '';
  }

  static Future<Uint8List?> bytes(String id) async {
    if (id.startsWith('gt-preset-')) return PresetFonts.bytes(id);
    final path = _paths[id];
    return path == null ? null : File(path).readAsBytes();
  }
}
