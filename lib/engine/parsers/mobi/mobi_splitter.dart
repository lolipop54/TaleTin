import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class MobiSplit {
  const MobiSplit(this.paths, this.anchors);
  final List<String> paths;
  final Map<String, String> anchors;
}

/// 流式读取旧 MOBI 的巨大 HTML，内存只保存头部、当前标签和少量正文。
/// 在块边界关闭/重新打开祖先标签，让跨片段的字体、缩进和容器样式继续生效。
Future<MobiSplit?> splitMobiHtml(
  File file, {
  void Function(int processedBytes)? onProgress,
}) async {
  return _scanMobiHtml(file.openRead(), _Splitter(file), onProgress);
}

/// Shares the legacy split decisions, recording source spans instead of files.
Future<MobiSplit?> indexMobiHtml(
  String name,
  Stream<List<int>> input,
  MobiSplitRecipes recipes,
) => _scanMobiHtml(input, _Splitter(File(name), recipes: recipes), null);

class MobiSplitRecipes {
  final segments = <String, List<Object>>{};
  List<Object>? _current;
  void start(String name) => _current = segments[name] = [];
  void raw(int offset, int length) {
    if (length == 0) return;
    final current = _current!;
    final last = current.lastOrNull;
    if (last is List<int> && last[0] + last[1] == offset) {
      last[1] += length;
    } else {
      current.add([offset, length]);
    }
  }

  void literal(String value) {
    if (value.isNotEmpty) _current!.add(value);
  }
}

Future<MobiSplit?> _scanMobiHtml(
  Stream<List<int>> bytes,
  _Splitter splitter,
  void Function(int)? onProgress,
) async {
  var pending = '';
  var processedBytes = 0;
  final input = bytes
      .map((bytes) {
        processedBytes += bytes.length;
        return bytes;
      })
      .transform(utf8.decoder);
  await for (final chunk in input) {
    pending += chunk;
    var at = 0;
    while (at < pending.length) {
      final rawTag = splitter.rawTag;
      if (rawTag != null) {
        final closing = RegExp(
          '</$rawTag\\s*>',
          caseSensitive: false,
        ).firstMatch(pending.substring(at));
        if (closing == null) {
          final keep = rawTag.length + 5;
          var until = pending.length - keep;
          if (until > at) {
            final unit = pending.codeUnitAt(until - 1);
            if (unit >= 0xd800 && unit <= 0xdbff) until--;
          }
          if (until > at) {
            splitter.text(pending.substring(at, until));
            at = until;
          }
          break;
        }
        final start = at + closing.start;
        splitter.text(pending.substring(at, start));
        final flush = splitter.tag(pending.substring(start, at + closing.end));
        if (flush != null) await flush;
        at += closing.end;
        continue;
      }
      final start = pending.indexOf('<', at);
      if (start < 0) {
        splitter.text(pending.substring(at));
        at = pending.length;
        break;
      }
      if (start > at) splitter.text(pending.substring(at, start));
      var end = start + 1;
      String? quote;
      if (pending.startsWith('<!--', start)) {
        final close = pending.indexOf('-->', start + 4);
        if (close < 0) {
          at = start;
          break;
        }
        end = close + 2;
      } else {
        for (; end < pending.length; end++) {
          final c = pending[end];
          if (quote != null) {
            if (c == quote) quote = null;
          } else if (c == '"' || c == "'") {
            quote = c;
          } else if (c == '>') {
            break;
          }
        }
        if (end == pending.length) {
          at = start;
          break;
        }
      }
      final flush = splitter.tag(pending.substring(start, end + 1));
      if (flush != null) await flush;
      at = end + 1;
    }
    pending = pending.substring(at);
    onProgress?.call(processedBytes);
  }
  splitter.text(pending);
  return splitter.finish();
}

class _Splitter {
  _Splitter(this.file, {this.recipes});
  final File file;
  final MobiSplitRecipes? recipes;
  static const _target = 64 * 1024;
  static const _void = {
    'area',
    'base',
    'br',
    'col',
    'embed',
    'hr',
    'img',
    'input',
    'link',
    'meta',
    'param',
    'source',
    'track',
    'wbr',
  };
  static const _blocks = {
    'p',
    'div',
    'section',
    'article',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'table',
    'ul',
    'ol',
    'blockquote',
    'pre',
    'hr',
  };
  static final _tag = RegExp(r'^<\s*(/?)\s*([\w:-]+)');
  static bool _word(int c) =>
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c == 95 ||
      c == 58 ||
      c == 45;

  static (String?, bool) _tagParts(String value) {
    final closing = value.length > 1 && value.codeUnitAt(1) == 47;
    final start = closing ? 2 : 1;
    if (value.length > start && _word(value.codeUnitAt(start))) {
      var end = start + 1;
      while (end < value.length && _word(value.codeUnitAt(end))) {
        end++;
      }
      return (value.substring(start, end).toLowerCase(), closing);
    }
    // 常见<p>／</div>直接扫描；带空白或特殊开头的标签仍走原正则，
    // 保留Unicode空白、注释及异常标签的原处理结果。
    final match = _tag.firstMatch(value);
    return (match?[2]?.toLowerCase(), match?[1] == '/');
  }

  static final _ids = RegExp(
    r'''\s(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );
  final _head = StringBuffer();
  final _stack = <(String, String, int)>[];
  final _paths = <String>[];
  final _anchors = <String, String>{};
  final _output = StringBuffer();
  IOSink? _sink;
  String _prefix = '';
  int _length = 0;
  int _sourceOffset = 0, _prefixBytes = 0;
  bool _body = false, _ended = false;
  String? rawTag;

  void text(String value) {
    final offset = _sourceOffset;
    final bytes = recipes == null ? 0 : _utf8Length(value);
    _sourceOffset += bytes;
    if (_ended) return;
    if (!_body) {
      _head.write(value);
      return;
    }
    _write(value, offset: offset, bytes: bytes);
    _length += value.length;
  }

  // 普通标签同步处理；只有真正切换文件时才创建并等待 Future。
  // 大合集有数百万个标签，逐个 await 和逐个编码写入会放大开销。
  Future<void>? tag(String value) {
    final offset = _sourceOffset;
    final bytes = recipes == null ? 0 : _utf8Length(value);
    _sourceOffset += bytes;
    if (_ended) return null;
    final (name, closing) = _tagParts(value);
    if (closing && name == rawTag) rawTag = null;
    if (!closing && {'script', 'style', 'title', 'textarea'}.contains(name)) {
      rawTag = name;
    }
    if (!_body) {
      _head.write(value);
      if (name == 'body' && !closing) {
        _body = true;
        _prefix = _head.toString();
        _prefixBytes = _sourceOffset;
        _head.clear();
        _start();
      }
      return null;
    }
    if (name == 'body' && closing) {
      _ended = true;
      return null;
    }
    if (name != null && !closing) {
      // HTML 的 p/li 可以省略闭标签；不能让这些标签堆积到后续片段。
      if (_blocks.contains(name)) _implicitClose('p');
      if (name == 'li') _implicitClose('li');
      if (_length >= _target &&
          _blocks.contains(name) &&
          !_stack.any(
            (t) => {
              'table',
              'pre',
              'svg',
              'math',
              'ol',
              'ul',
              'dl',
            }.contains(t.$1),
          )) {
        return _next(value, name, offset, bytes);
      }
    }
    _writeTag(value, name, closing, offset, bytes);
    return null;
  }

  Future<void> _next(String value, String name, int offset, int bytes) async {
    await _close();
    _start();
    _writeTag(value, name, false, offset, bytes);
  }

  void _writeTag(
    String value,
    String? name,
    bool closing,
    int offset,
    int bytes,
  ) {
    if (name != null && !closing && value.contains('=')) {
      for (final id in _ids.allMatches(value)) {
        _anchors[id[1] ?? id[2] ?? id[3]!] = _paths.last;
      }
    }
    _write(value, offset: offset, bytes: bytes);
    _length += value.length;
    if (name == null) return;
    if (closing) {
      final index = _stack.lastIndexWhere((t) => t.$1 == name);
      if (index >= 0) _stack.removeRange(index, _stack.length);
    } else if (!_void.contains(name) && !value.endsWith('/>')) {
      _stack.add((name, value, offset));
    }
  }

  void _write(String value, {int? offset, int? bytes}) {
    final recorder = recipes;
    if (recorder != null) {
      if (offset == null) {
        recorder.literal(value);
      } else {
        recorder.raw(offset, bytes ?? _utf8Length(value));
      }
      return;
    }
    _output.write(value);
    // 不拆分表格/列表，但写盘缓冲仍有上限，不长期积累整张表。
    if (_output.length >= _target) _flush();
  }

  void _flush() {
    if (_output.isEmpty) return;
    _sink!.write(_output.toString());
    _output.clear();
  }

  void _implicitClose(String name) {
    final index = _stack.lastIndexWhere((t) => t.$1 == name);
    if (index >= 0) _stack.removeRange(index, _stack.length);
  }

  void _start() {
    final name =
        '${p.basenameWithoutExtension(file.path)}-s${_paths.length.toString().padLeft(5, '0')}.html';
    _paths.add(name);
    if (recipes == null) {
      _sink = File(p.join(file.parent.path, name)).openWrite();
      _write(_prefix);
    } else {
      recipes!.start(name);
      recipes!.raw(0, _prefixBytes);
    }
    // 每片都是独立文档，祖先 id 也须保留，书中的 #容器 样式才继续生效。
    // 锚点映射只在原节点经过 tag() 时登记，链接仍指向最初出现的位置。
    for (final tag in _stack) {
      _write(tag.$2, offset: tag.$3);
    }
    _length = 0;
  }

  Future<void> _close() async {
    for (final tag in _stack.reversed) {
      _write('</${tag.$1}>');
    }
    _write('</body></html>');
    _flush();
    await _sink?.close();
  }

  Future<MobiSplit?> finish() async {
    if (!_body) return null;
    await _close();
    return MobiSplit(_paths, _anchors);
  }
}

// Count valid UTF-8 source bytes without allocating an encoded list per tag.
int _utf8Length(String text) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      count++;
    } else if (unit < 0x800) {
      count += 2;
    } else if (unit >= 0xd800 &&
        unit <= 0xdbff &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xdc00 &&
        text.codeUnitAt(i + 1) <= 0xdfff) {
      count += 4;
      i++;
    } else {
      count += 3;
    }
  }
  return count;
}
