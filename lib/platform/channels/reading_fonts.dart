import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';

import 'preset_fonts.dart';
import 'imported_fonts.dart';
import '../../data/services/imported_font_store.dart';
import '../../core/diagnostics/reader_work_trace.dart';

/// 内置字体与平台确认的设备字体：预览、Flutter 正文和 WebView 共用。
abstract final class ReadingFonts {
  static final _paths = <String, String>{};
  static final _aliases = <String, String>{};
  static final _names = <String, String?>{...PresetFonts.names};
  static Future<Map<String, String?>>? _pending;
  static Future<String?>? _system;
  static final _layoutDigests = <String, Future<String?>>{};
  static final _fileDigests = <String, String>{};
  static Future<String?>? _environmentDigest;

  static void configureImported(ImportedFontStore store) {
    ImportedFonts.configure(store);
    _names.removeWhere((key, _) => key.startsWith('gt-import-'));
    _pending = null;
    _layoutDigests.clear();
  }

  /// 导入不写阅读设置；完整候选准备好后，调用方再更新页面的字体名单。
  static Future<Map<String, String?>> refreshImported() async {
    final imported = await ImportedFonts.load();
    _names.removeWhere((key, _) => key.startsWith('gt-import-'));
    _names.addAll(imported);
    _pending = Future.value({..._names});
    _layoutDigests.clear();
    return {..._names};
  }

  /// 排版磁盘缓存只认实际已注册的字体文件；未知回退不产生可信摘要。
  static Future<String?> layoutFingerprint(String? family) async {
    final id = resolve(family);
    if (id == null) return null;
    return _layoutDigests[id] ??= () async {
      try {
        final primary =
            ImportedFonts.fingerprint(id) ??
            _fileDigests[id] ??
            await _presetDigest(id);
        if (primary == null) return null;
        final system = await loadSystem();
        final fallback = system == id ? primary : _fileDigests[system];
        if (fallback == null) return null;
        final environment = await (_environmentDigest ??= const MethodChannel(
          'gtreader/reading_fonts',
        ).invokeMethod<String>('environmentDigest'));
        if (environment == null) return null;
        final bold = PresetFonts.families[id]?.bold;
        if (bold == null) return '$primary:$fallback:$environment';
        final extra = await _assetDigest('${PresetFonts.root}$bold');
        return extra == null ? null : '$primary:$fallback:$extra:$environment';
      } on Object {
        return null;
      }
    }();
  }

  static Future<String?> _presetDigest(String id) {
    final preset = PresetFonts.families[id];
    return preset == null
        ? Future.value(null)
        : _assetDigest('${PresetFonts.root}${preset.file}');
  }

  /// Android 复用平台 SHA 实现，避免在开书前把整套字体搬进 Dart 再重复计算。
  static Future<String?> _assetDigest(String asset) async {
    try {
      return await const MethodChannel('gtreader/reading_fonts')
          .invokeMethod<String>('assetDigest', {'asset': asset});
    } on MissingPluginException {
      final data = await rootBundle.load(asset);
      return Isolate.run(
        () => sha256.convert(data.buffer.asUint8List()).toString(),
      );
    }
  }

  /// 首页只准备当前系统字体，完整目录仍在字体页打开前准备。
  static Future<String?> loadSystem() =>
      _system ??= _load('system').then((_) => resolve('sans-serif'));

  static Future<Map<String, String?>> load() => _pending ??= () async {
    await loadSystem();
    final imported = await ImportedFonts.load();
    _names.addAll(imported);
    return {...await _load('list'), ...PresetFonts.names, ...imported};
  }();

  /// 阅读只准备实际选择的字体；完整名单和所有预览留到字体选择页。
  static Future<String?> loadSelected(String? family) =>
      traceReaderWork('font.load_selected', () => _loadSelected(family), {
        'family': family,
        'hasSystemTask': _system != null,
        'isPreset': PresetFonts.families.containsKey(family),
      });

  static Future<String?> _loadSelected(String? family) async {
    if (family == null || family == 'sans-serif') return loadSystem();
    if (family.startsWith('gt-import-')) {
      if (!await ImportedFonts.loadSelected(family)) return loadSystem();
      final item = ImportedFonts.store!.families.firstWhere(
        (f) => f.id == family,
      );
      _names[family] = '${item.name}（导入）';
      return family;
    }
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
    _layoutDigests.clear();
    _environmentDigest = null;
    await loadSystem();
  }

  static Future<Map<String, String?>> _load(
    String method, {
    String? family,
  }) async {
    final trace = ReaderWorkTrace.start('font.platform_and_load', {
      'method': method,
      'family': family,
    });
    try {
      final entries =
          await const MethodChannel('gtreader/reading_fonts')
              .invokeListMethod<dynamic>(
                method,
                family == null ? null : {'family': family},
              ) ??
          [];
      trace?.mark('platform_reply');
      trace?.details['entries'] = entries.length;
      final names = <String, String?>{};
      final loading = <Future<void>>[];
      final paths = <String, String>{};
      final digests = <String, String>{};
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
        if (entry['digest'] case final String digest) digests[id] = digest;
        names[id] = entry['name'] as String;
        for (final alias in entry['aliases'] as List) {
          aliases[alias as String] = id;
        }
      }
      // 独立字体并行加载，全部完成后才发布名单和预览。
      await Future.wait(loading);
      trace?.mark('font_bytes_and_registration');
      _paths.addAll(paths);
      _fileDigests.addAll(digests);
      _aliases.addAll(aliases);
      _names.addAll(names);
      return names;
    } on MissingPluginException {
      return const {};
    } finally {
      trace?.finish();
    }
  }

  /// 兼容旧的 serif/KaiTi 设置；只映射平台已确认的回退关系。
  static String? resolve(String? family) {
    final unavailableImport =
        family != null &&
        family.startsWith('gt-import-') &&
        ImportedFonts.store != null &&
        !ImportedFonts.store!.families.any((f) => f.id == family);
    final available =
        unavailableImport ||
            family != null &&
                family.startsWith('gt-preset-') &&
                !PresetFonts.families.containsKey(family)
        ? 'sans-serif'
        : family;
    return _aliases[available ?? 'sans-serif'] ?? available;
  }

  static String cssFor(String? family, {bool nativeAssets = false}) {
    if (family == null || family.isEmpty) return '';
    final id = resolve(family);
    if (PresetFonts.families.containsKey(id)) {
      return PresetFonts.cssFor(id!, nativeAssets: nativeAssets);
    }
    if (id != null && id.startsWith('gt-import-')) {
      return ImportedFonts.cssFor(id);
    }
    return _paths.containsKey(id)
        ? '@font-face{font-family:"$id";src:url("/__gt_fonts/$id");}'
        : '';
  }

  static Future<Uint8List?> bytes(String id) async {
    if (id.startsWith('gt-import-face-')) return ImportedFonts.bytes(id);
    if (id.startsWith('gt-preset-')) return PresetFonts.bytes(id);
    final path = _paths[id];
    return path == null ? null : File(path).readAsBytes();
  }
}
