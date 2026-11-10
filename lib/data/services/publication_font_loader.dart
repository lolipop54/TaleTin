import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/app_errors.dart';
import '../../domain/models/book_document.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/layout/layout_options.dart';
import '../../engine/layout/publication_font_set.dart';
import '../../engine/styles/chapter_styler.dart';
import '../../engine/styles/css_layout_styles.dart';
import 'epub_source_repository.dart';

/// 从当前章的 CSS 找到实际需要的书内字体。读取、解混淆和缓存沿用书籍资源服务。
class PublicationFontLoader {
  PublicationFontLoader(this._openSource);

  final Future<EpubSourceSession?> Function(String) _openSource;
  final _prepared = Expando<Map<String, Future<PublicationFontSet>>>();
  // Flutter 注册后按进程持有字体。相同字节使用同一个别名，不按书重复注册。
  static final _registered = <String, Future<String?>>{};

  Future<LayoutOptions> prepare(
    String bookId,
    ChapterContent content,
    LayoutOptions options,
  ) async {
    if (!options.settings.useBookFontsInSimplified) return options;
    final chapter = CssLayoutStyles.resolve(content, options);
    final declarations = chapter.displaySourceJson?['fontFaces'];
    if (declarations is! List || declarations.isEmpty) return options;
    final used = {
      for (final style in ChapterStyler.layoutTableOf(chapter).records)
        for (final name in style.text.fontFamilies ?? const <String>[])
          name.toLowerCase(),
    };
    final faces = [
      for (final raw in declarations.whereType<Map>())
        if (raw['family'] case final String name)
          if (used.contains(name.toLowerCase())) raw,
    ];
    if (faces.isEmpty) return options;
    final key = jsonEncode(faces);
    final pending = _prepared[content] ??= {};
    // 同时可能有正页、邻页和翻页动画请求同一章。
    if (pending.length >= 2 && !pending.containsKey(key)) {
      pending.remove(pending.keys.first);
    }
    final task = pending[key] ??= _load(bookId, faces);
    try {
      return options.withPublicationFonts(await task);
    } catch (_) {
      if (identical(pending[key], task)) pending.remove(key);
      rethrow;
    }
  }

  Future<PublicationFontSet> _load(String bookId, List<Map> faces) async {
    EpubSourceSession? source;
    final families = <String, List<PublicationFace>>{};
    final loadedPaths = <String, String?>{};
    try {
      source = await _openSource(bookId);
      if (source == null) return PublicationFontSet.empty;
      for (final face in faces) {
        final name = (face['family'] as String).toLowerCase();
        final style = (face['style'] as String).toLowerCase();
        final weights = (face['weight'] as String).trim().toLowerCase().split(
          RegExp(r'\s+'),
        );
        int weight(String token) => switch (token) {
          'normal' => 400,
          'bold' => 700,
          _ => (int.tryParse(token) ?? 400).clamp(1, 1000),
        };
        final min = weight(weights.first);
        final max = weight(weights.last).clamp(min, 1000);
        for (final path in (face['sources'] as List).cast<String>()) {
          if (!path.startsWith('res/')) continue;
          final entry = path.substring(4);
          final alias = loadedPaths.containsKey(entry)
              ? loadedPaths[entry]
              : loadedPaths[entry] = await _registerResource(source, entry);
          if (alias == null) continue;
          (families[name] ??= []).add((
            alias: alias,
            minWeight: min,
            maxWeight: max,
            italic: style == 'italic' || style.startsWith('oblique'),
          ));
          break;
        }
      }
    } on Object catch (error, stack) {
      if (error is ContentFailure &&
          error.code == ContentErrorCode.sourceChanged) {
        rethrow;
      }
      AppErrors.report(error, stack, operation: '读取原书字体失败', notify: false);
    } finally {
      await source?.close();
    }
    if (families.isEmpty) return PublicationFontSet.empty;
    final identity = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final entry in families.entries)
                [
                  entry.key,
                  for (final f in entry.value)
                    [f.alias, f.minWeight, f.maxWeight, f.italic],
                ],
            ]),
          ),
        )
        .toString();
    return PublicationFontSet(families, identity);
  }

  Future<String?> _registerResource(
    EpubSourceSession source,
    String entry,
  ) async {
    try {
      final data = await source.fontResource(entry);
      if (data == null || data.bytes.length < 12) return null;
      final bytes = data.bytes;
      final magic = ByteData.sublistView(bytes).getUint32(0);
      if (!{
        0x00010000, // TTF
        0x4f54544f, // OTF
        0x74746366, // TTC
        0x74727565, // TrueType
        0x774f4646, // WOFF
        0x774f4632, // WOFF2
      }.contains(magic)) {
        return null;
      }
      final alias = 'gt-book-${data.digest}';
      final task = _registered[alias] ??= _register(alias, bytes);
      final result = await task;
      if (result == null && identical(_registered[alias], task)) {
        _registered.remove(alias);
      }
      return result;
    } on Object catch (error, stack) {
      if (error is ContentFailure &&
          error.code == ContentErrorCode.sourceChanged) {
        rethrow;
      }
      AppErrors.report(error, stack, operation: '加载书内字体失败', notify: false);
      return null;
    }
  }

  Future<String?> _register(String alias, Uint8List bytes) async {
    try {
      if (Platform.isAndroid) {
        await const MethodChannel('gtreader/reading_fonts')
            .invokeMethod<void>('validatePublication', bytes);
      }
      final loader = FontLoader(alias)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      return alias;
    } on Object catch (error, stack) {
      AppErrors.report(error, stack, operation: '书内字体无法解码', notify: false);
      return null;
    }
  }
}
