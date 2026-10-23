import 'dart:convert';
import 'dart:typed_data';

import 'package:direct_read_rust/mobi_html.dart';
import 'package:direct_read_rust/mobi_html_batch.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'mobi_splitter.dart';

/// These are the existing publication's link/media and serialization rules.
/// Apply to the requested entry, after native reconstruction and segmentation.
class MobiRewriter {
  MobiRewriter(this.kf8, this.splits, this.originals);
  final bool kf8;
  final Map<String, MobiSplit> splits;
  final Map<String, String> originals;
  static final _template = RegExp(r'<template(?:\s|/?>)', caseSensitive: false);

  String link(String raw, String name) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.hasScheme || uri.hasAuthority) return raw;
    final target = uri.path.isEmpty ? originals[name] ?? name : uri.path;
    final split = splits[target];
    if (split == null) return raw;
    return Uri(
      path: split.anchors[uri.fragment] ?? split.paths.first,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  }

  String _media(String value) => value
      .replaceAll('amzn-kf8', kf8 ? 'screen' : 'taletin-kf8-disabled')
      .replaceAll('amzn-mobi', kf8 ? 'taletin-mobi-disabled' : 'screen');
  String _stylesheet(String value) => value.replaceAllMapped(
    RegExp(r'(@media\s+)([^{}]+)(\{)', caseSensitive: false),
    (m) => '${m[1]}${_media(m[2]!)}${m[3]}',
  );

  String rewrite(String text, String name) {
    final extension = p.extension(name).toLowerCase();
    if (extension == '.css') return _stylesheet(text);
    if (extension == '.html' || extension == '.xhtml') {
      // package:html predates HTML template parsing. Its template placement and
      // child traversal differ from html5ever, so preserve the existing parser
      // for entries containing this uncommon construct.
      if (_template.hasMatch(text)) {
        return _templateHtml(text, name);
      }
      final document = NativeMobiHtml(text);
      try {
        return document.finish(_edits(document.refs, name));
      } finally {
        document.close();
      }
    }
    if (extension == '.opf' || extension == '.ncx') {
      final document = XmlDocument.parse(text);
      for (final element in document.descendantElements) {
        for (final attribute in ['href', 'src']) {
          final value = element.getAttribute(attribute);
          if (value != null) element.setAttribute(attribute, link(value, name));
        }
      }
      return document.toXmlString();
    }
    return text;
  }

  /// 只改变同批章节的调度；链接、媒体条件和序列化仍共用单章规则。
  List<Uint8List> rewriteBatch(List<String> texts, List<String> names) {
    final result = List<Uint8List?>.filled(texts.length, null);
    final parallel = <int>[];
    for (var i = 0; i < texts.length; i++) {
      final extension = p.extension(names[i]).toLowerCase();
      if ((extension == '.html' || extension == '.xhtml') &&
          !_template.hasMatch(texts[i])) {
        parallel.add(i);
      } else {
        // template保留package:html，XML／CSS也不改变原来的处理器。
        result[i] = Uint8List.fromList(
          utf8.encode(rewrite(texts[i], names[i])),
        );
      }
    }
    if (parallel.isNotEmpty) {
      final batch = NativeMobiHtmlBatch([for (final i in parallel) texts[i]]);
      try {
        final refs = batch.refs;
        final bytes = batch.finish([
          for (var i = 0; i < parallel.length; i++)
            _edits(refs[i], names[parallel[i]]),
        ]);
        for (var i = 0; i < parallel.length; i++) {
          result[parallel[i]] = bytes[i];
        }
      } finally {
        batch.close();
      }
    }
    return result.cast<Uint8List>();
  }

  List<List<Object>> _edits(List<List<dynamic>> refs, String name) {
    final edits = <List<Object>>[];
    for (final node in refs) {
      for (var i = 1; i <= 2; i++) {
        if (node[i] case final String value) {
          edits.add([
            node[0] as int,
            i == 1 ? 'href' : 'src',
            link(value, name),
          ]);
        }
      }
      if (node[3] case final String media) {
        edits.add([node[0] as int, 'media', _media(media)]);
      }
      if (node[4] case final String style) {
        edits.add([node[0] as int, 'styleText', _stylesheet(style)]);
      }
    }
    return edits;
  }

  String _templateHtml(String text, String name) {
    final document = html.parse(text);
    for (final element in document.querySelectorAll(
      '[href], [src], [media], style',
    )) {
      for (final attribute in ['href', 'src']) {
        final value = element.attributes[attribute];
        if (value != null) element.attributes[attribute] = link(value, name);
      }
      final media = element.attributes['media'];
      if (media != null) element.attributes['media'] = _media(media);
      if (element.localName == 'style') {
        element.text = _stylesheet(element.text);
      }
    }
    return document.outerHtml;
  }
}
