import 'dart:convert';
import 'dart:io';

import 'package:direct_read_rust/direct_read_rust.dart';
import 'package:path/path.dart' as p;

import '../../../core/diagnostics/import_timing.dart';
import 'epub_archive.dart';

/// 全表对照只在显式构建性能包时启用。
const publicationCssMode = String.fromEnvironment(
  'GT_EPUB_CSS',
  defaultValue: 'indexed',
);

/// 一本书的一次导入。外链以 EPUB 路径为键，章内样式使用独立编号；
/// 引用上的 media 和重复引用不参与文件去重。
class PublicationStyleTree {
  PublicationStyleTree(this.readCss, {this.timing});
  final String? Function(String path) readCss;
  final ImportTiming? timing;
  final _sheets = <String, Object?>{};
  final _chapters = <String, List<List<String>>>{};
  final _visited = <String>{};
  NativeHtml? _compiler;
  int _nextInline = 0;

  static File file(String directory, String digest) =>
      File(p.join(directory, 'css-tree-2-$digest.json'));

  final _openingChapters = <String, List<String>>{};
  void chapter(String path, List<dynamic> tags, [List<dynamic>? opening]) {
    if (opening != null) {
      final asset = resolveEntryPath(path, opening[0] as String);
      if (asset != null) (_openingChapters['asset:$asset'] ??= []).add(path);
      if (opening[1] != null || opening[2] != null) {
        (_openingChapters['class:${jsonEncode(opening.sublist(1))}'] ??= [])
            .add(path);
      }
    }
    final refs = <List<String>>[];
    for (final tag in tags.cast<Map>()) {
      final text = tag['value'] as String;
      late String id;
      if (tag['inline'] == true) {
        if (text.trim().isEmpty) continue;
        // NUL 不能出现在书内文件名中，不会与外链路径冲突。
        id = '\u0000${_nextInline++}';
        _compile(id, path, text);
      } else {
        final entry = resolveEntryPath(path, text);
        if (entry == null) continue;
        id = entry;
        _external(entry);
        if (!_sheets.containsKey(id)) continue;
      }
      refs.add([id, (tag['media'] as String? ?? '').trim()]);
    }
    _chapters[path] = refs;
  }

  void _external(String path) {
    if (!_visited.add(path)) return;
    final text = readCss(path);
    if (text != null) _compile(path, path, text);
  }

  void _compile(String id, String path, String text) {
    final native = _compiler ??= NativeHtml('');
    Map<String, dynamic> compile() => native.convert({
      'cssTreeCommand': {'path': path, 'text': text},
    });
    final result = timing?.detail('css_compile', compile) ?? compile();
    timing?.count('css_sheets', 1);
    _sheets[id] = result['sheet'] as Map;
    for (final imported in (result['imports'] as List).cast<String>()) {
      _external(imported);
    }
  }

  void save(String directory, String digest) {
    final dest = file(directory, digest);
    dest.parent.createSync(recursive: true);
    // 不同 worker 可能同时补建同一本旧书，各自写完再发布完整文件。
    final stage = dest.parent.createTempSync('.css-tree-');
    try {
      final tmp = File(p.join(stage.path, 'book.json'));
      tmp.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'digest': digest,
          'sheets': _sheets,
          'chapters': _chapters,
          'openingChapters': {
            for (final group in _openingChapters.values)
              if (group.length > 1) ...group,
          }.toList(),
        }),
        flush: true,
      );
      tmp.renameSync(dest.path);
    } finally {
      stage.deleteSync(recursive: true);
    }
  }

  void close() => _compiler?.close();

  static bool bind(String directory, String digest) {
    final store = file(directory, digest);
    if (!store.existsSync()) return false;
    final native = NativeHtml('');
    try {
      return native.convert({
            'cssTreeCommand': {'file': store.path, 'digest': digest},
          })['ok'] ==
          true;
    } finally {
      native.close();
    }
  }
}
