import 'dart:io';

import 'package:flutter/services.dart';

import '../../data/services/imported_font_store.dart';
import '../../domain/models/imported_font.dart';

/// 同一份持久字体供 Flutter 和 WebView 使用，资源地址只包含内容摘要。
abstract final class ImportedFonts {
  static ImportedFontStore? store;
  static final _loaded = <String, String>{};
  static final _families = <String, ImportedFontFamily>{};

  static void configure(ImportedFontStore value) {
    store = value;
    _families.clear();
    _loaded.clear();
  }

  static Future<Map<String, String?>> load() async {
    final current = store;
    if (current == null) return {};
    await current.load();
    for (final family in current.families) {
      await prepare(family);
    }
    _families
      ..clear()
      ..addEntries(current.families.map((f) => MapEntry(f.id, f)));
    return {for (final f in current.families) f.id: '${f.name}（导入）'};
  }

  static Future<bool> loadSelected(String id) async {
    final current = store;
    if (current == null) return false;
    await current.load();
    for (final family in current.families) {
      if (family.id != id) continue;
      await prepare(family);
      _families[id] = family;
      return true;
    }
    return false;
  }

  static Future<void> prepare(ImportedFontFamily family) async {
    if (_loaded[family.id] == family.fingerprint) return;
    final current = store!;
    final loader = FontLoader(family.id);
    for (final face in family.faces) {
      final file = current.faceFile(face);
      // FontLoader 的平台解码失败未必抛 Dart 异常，先让 Android 解码器验证。
      if (Platform.isAndroid) {
        await const MethodChannel('gtreader/reading_fonts')
            .invokeMethod<void>('validateImported', {'path': file.path});
      }
      loader.addFont(file.readAsBytes().then(ByteData.sublistView));
    }
    await loader.load();
    _loaded[family.id] = family.fingerprint;
  }

  static String? fingerprint(String? family) => _families[family]?.fingerprint;
  static String cssFor(String id) {
    final family = _families[id];
    if (family == null) return '';
    return family.faces
        .map(
          (face) =>
              '@font-face{font-family:"$id";'
              'src:url("/__gt_fonts/${face.resource}");'
              'font-weight:${face.minWeight == face.maxWeight ? '${face.minWeight}' : '${face.minWeight} ${face.maxWeight}'};'
              'font-style:${face.style};}',
        )
        .join();
  }

  static Future<Uint8List?> bytes(String resource) async {
    for (final family in _families.values) {
      for (final face in family.faces) {
        if (face.resource == resource) {
          return store!.faceFile(face).readAsBytes();
        }
      }
    }
    return null;
  }
}
