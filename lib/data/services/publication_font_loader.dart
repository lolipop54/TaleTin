import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/app_errors.dart';
import '../../core/diagnostics/reader_work_trace.dart';
import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/layout/layout_options.dart';
import '../../engine/layout/publication_font_set.dart';
import '../../engine/styles/chapter_styler.dart';
import '../../engine/styles/css_layout_styles.dart';
import '../../platform/reading_font_binding.dart';
import 'epub_source_repository.dart';

/// 从当前章的 CSS 找到实际需要的书内字体。读取、解混淆和缓存沿用书籍资源服务。
class PublicationFontLoader {
  PublicationFontLoader(this._openSource, {this.sourceIdentity});

  final Future<EpubSourceSession?> Function(String) _openSource;
  final Future<Object?> Function(String, Book?)? sourceIdentity;
  final _localSources = Expando<Object>();
  final _pending = <Object, Future<PublicationFontSet>>{};
  // null 表示该版归档缺少文件或文件头不是字体。临时读取或注册失败仍会重试。
  final _aliases = <(Object, String), String?>{};
  final _reading = <String, _FontBookWindow>{};
  // Flutter 注册后按进程持有字体。相同字节使用同一个别名，不按书重复注册。
  static final _registered = <String, Future<String?>>{};

  /// 当前读书会话可借用同一份已核验的归档。最后一个读者退出便关闭。
  void Function() retainBook(Book book) {
    final bookId = book.id;
    final window = _reading.putIfAbsent(bookId, () => _FontBookWindow(book));
    window.book = book;
    window.readers++;
    return () {
      if (--window.readers == 0) {
        _reading.remove(bookId);
        unawaited(window.idle?.close());
      }
    };
  }

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
    final identity = (
      bookId,
      await sourceIdentity?.call(bookId, _reading[bookId]?.book) ??
          (_localSources[content] ??= Object()),
    );
    final key = (identity, jsonEncode(faces));
    final task = _pending[key] ??= _load(bookId, identity, faces);
    try {
      return options.withPublicationFonts(await task);
    } finally {
      if (identical(_pending[key], task)) _pending.remove(key);
    }
  }

  Future<PublicationFontSet> _load(
    String bookId,
    Object sourceKey,
    List<Map> faces,
  ) async {
    EpubSourceSession? source;
    final window = _reading[bookId];
    final families = <String, List<PublicationFace>>{};
    final loadedPaths = <String, String?>{};
    try {
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
        final sources = (face['sources'] as List).cast<String>();
        String? alias;
        for (final path in sources) {
          if (!path.startsWith('res/')) continue;
          final entry = path.substring(4);
          final key = (sourceKey, entry);
          if (_aliases.containsKey(key)) {
            alias = _aliases.remove(key);
            _aliases[key] = alias;
          } else if (loadedPaths.containsKey(entry)) {
            alias = loadedPaths[entry];
          } else {
            source ??= window?.take(sourceKey) ?? await _openSource(bookId);
            if (source == null) return PublicationFontSet.empty;
            var unusable = false;
            alias = await _registerResource(
              source,
              entry,
              () => unusable = true,
            );
            loadedPaths[entry] = alias;
            if (alias != null || unusable) {
              _aliases[key] = alias;
              if (_aliases.length > 128) _aliases.remove(_aliases.keys.first);
            }
          }
          if (alias != null) break;
        }
        if (alias != null) {
          (families[name] ??= []).add((
            alias: alias,
            minWeight: min,
            maxWeight: max,
            italic: style == 'italic' || style.startsWith('oblique'),
          ));
        }
      }
    } on Object catch (error, stack) {
      if (error is ContentFailure &&
          error.code == ContentErrorCode.sourceChanged) {
        rethrow;
      }
      AppErrors.report(error, stack, operation: '读取原书字体失败', notify: false);
    } finally {
      if (source != null &&
          window != null &&
          identical(_reading[bookId], window)) {
        window.put(sourceKey, source);
      } else {
        await source?.close();
      }
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
    void Function() onUnusable,
  ) async {
    try {
      final data = await source.fontResource(entry, onAbsent: onUnusable);
      if (data == null) return null;
      final bytes = data.bytes;
      if (bytes.length < 12) {
        onUnusable();
        return null;
      }
      final magic = ByteData.sublistView(bytes).getUint32(0);
      if (!{
        0x00010000, // TTF
        0x4f54544f, // OTF
        0x74746366, // TTC
        0x74727565, // TrueType
        0x774f4646, // WOFF
        0x774f4632, // WOFF2
      }.contains(magic)) {
        onUnusable();
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
    final trace = ReaderWorkTrace.start('font.register', {'bytes': bytes.length});
    try {
      if (Platform.isAndroid) {
        await const MethodChannel('gtreader/reading_fonts')
            .invokeMethod<void>('validatePublication', bytes);
      }
      trace?.mark('validate');
      final loader = FontLoader(alias)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await ReadingFontBinding.registerBookFont(loader);
      trace?.mark('register');
      return alias;
    } on Object catch (error, stack) {
      AppErrors.report(error, stack, operation: '书内字体无法解码', notify: false);
      return null;
    } finally {
      trace?.finish();
    }
  }
}

/// 只留一个空闲会话。正在读取的会话由调用方独占，归还或退出都不会关掉在途读取。
class _FontBookWindow {
  _FontBookWindow(this.book);
  Book book;
  int readers = 0;
  Object? identity;
  EpubSourceSession? idle;

  EpubSourceSession? take(Object key) {
    final source = idle;
    idle = null;
    if (identity == key && source?.isClosed == false) return source;
    unawaited(source?.close());
    return null;
  }

  void put(Object key, EpubSourceSession source) {
    unawaited(idle?.close());
    identity = key;
    idle = source;
  }
}
