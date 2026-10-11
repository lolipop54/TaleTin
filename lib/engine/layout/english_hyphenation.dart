import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:hyphen/hyphen.dart';

import '../normalization/display_hyphens.dart';
export '../normalization/display_hyphens.dart';

/// Hunspell 英文词典只加载一次，词级结果小量缓存；不改变书籍文件。
abstract final class EnglishHyphenation {
  static Hyphen? _dictionary;
  static Future<void>? _preparing;
  static final _words = <String, List<int>>{};
  static final _word = RegExp(r'[A-Za-z]{5,}');

  static Future<void> prepare() {
    // 已准备好时直接返回，不继续持有首次资源加载所在的异步上下文。
    if (_dictionary != null) return Future.value();
    return _preparing ??= _load();
  }

  static Future<void> _load() async {
    final bytes = await rootBundle.load('assets/hyphenation/hyph_en_US.dic');
    prepareFromBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }

  /// 后台原书会话使用主线程读取的词典字节，在自己的 isolate 内解析。
  /// 与普通 prepare 共用同一个词典和断字算法，不改变软连字符的位置。
  static void prepareFromBytes(Uint8List bytes) {
    _dictionary ??= Hyphen.fromDictionaryBytes(bytes);
  }

  static HyphenatedText display(String source) {
    final dictionary = _dictionary;
    if (dictionary == null) return HyphenatedText(source, const []);
    final points = <int>{};
    for (final match in _word.allMatches(source)) {
      final word = match.group(0)!;
      final key = word.toLowerCase();
      final breaks = _words.putIfAbsent(key, () {
        final parts = dictionary.hyphenate(key, lhmin: 2, rhmin: 3);
        var offset = 0;
        return [
          for (final part in parts.take(parts.length - 1))
            offset += part.length,
        ];
      });
      for (final point in breaks) {
        points.add(match.start + point);
      }
    }
    if (_words.length > 1024) _words.clear();
    final buffer = StringBuffer();
    final inserted = <int>[];
    for (var i = 0; i < source.length; i++) {
      if (points.contains(i)) {
        inserted.add(buffer.length);
        buffer.write('\u00ad');
      }
      buffer.writeCharCode(source.codeUnitAt(i));
    }
    return HyphenatedText(buffer.toString(), inserted);
  }

  /// 原书保留节点结构，父节点属性记录新增字符的位置，DOM ↔ Locator 可准确换算。
  /// 已有软连字符不在新增名单里，不能误删书籍原来的字符。
  static String document(String source) {
    final document = html.parse(source);
    final body = document.body;
    if (body == null) return source;
    void walk(Node node, bool prose) {
      if (node is Text && prose) {
        final displayText = display(node.text);
        if (displayText.insertions.isEmpty) return;
        final parent = node.parent!;
        final index = parent.nodes.indexOf(node);
        parent.attributes['data-gt-hyphens-$index'] = jsonEncode(
          displayText.insertions,
        );
        node.text = displayText.text;
      } else if (node is Element) {
        final tag = node.localName;
        if ([
          'script',
          'style',
          'pre',
          'code',
          'h1',
          'h2',
          'h3',
          'h4',
          'h5',
          'h6',
        ].contains(tag)) {
          return;
        }
        for (final child in node.nodes) {
          walk(child, prose || ['p', 'li', 'blockquote', 'div'].contains(tag));
        }
      }
    }

    walk(body, false);
    return document.outerHtml;
  }
}
