import 'package:html/parser.dart' as html;

import 'epub_package.dart';

/// 部分转换书把多个章题写成同一个无锚点地址。仅对这类冲突核对文档标题，
/// 不用正文中偶然出现的章名猜位置，也不改有效的章内锚点。
class TocTargetRecovery {
  TocTargetRecovery(List<RawTocEntry> entries) {
    final titles = <String, Set<String>>{};
    void visit(List<RawTocEntry> nodes) {
      for (final node in nodes) {
        if (node.href != null && (node.fragment?.isEmpty ?? true)) {
          (titles[node.href!] ??= {}).add(_key(node.title));
        }
        visit(node.children);
      }
    }

    visit(entries);
    conflicts = {
      for (final entry in titles.entries)
        if (entry.value.length > 1) entry.key,
    };
  }

  late final Set<String> conflicts;
  final _titles = <String, String>{};
  final _headings = <String, Set<String>>{};
  final _headingIds = <String, Map<String, List<String>>>{};
  bool get needed => conflicts.isNotEmpty;

  void record(String path, String source) {
    if (!needed) return;
    final match = RegExp(
      r'<title\b[^>]*>([\s\S]*?)</title\s*>',
      caseSensitive: false,
    ).firstMatch(source);
    if (match != null) {
      _titles[path] = _key(html.parseFragment(match[1]!).text ?? '');
    }
    if (conflicts.contains(path)) {
      _headings[path] = {
        for (final heading in RegExp(
          r'<h[1-6]\b[^>]*>([\s\S]*?)</h[1-6]\s*>',
          caseSensitive: false,
        ).allMatches(source))
          _key(html.parseFragment(heading[1]!).text ?? ''),
      };
      final document = html.parse(source);
      final ids = <String, List<String>>{};
      for (final heading in document.querySelectorAll(
        'h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]',
      )) {
        (ids[_key(heading.text)] ??= []).add(heading.id);
      }
      _headingIds[path] = ids;
    }
  }

  List<RawTocEntry> recover(List<RawTocEntry> entries) {
    if (!needed || entries.isEmpty) return entries;
    final paths = <String, List<String>>{};
    for (final entry in _titles.entries) {
      (paths[entry.value] ??= []).add(entry.key);
    }
    return [
      for (final entry in entries)
        RawTocEntry(
          title: entry.title,
          href: () {
            if (!conflicts.contains(entry.href) ||
                (entry.fragment?.isNotEmpty ?? false) ||
                _titles[entry.href] == _key(entry.title) ||
                (_headings[entry.href]?.contains(_key(entry.title)) ?? false)) {
              return entry.href;
            }
            final matches = paths[_key(entry.title)] ?? const <String>[];
            // 大HTML分段会复制head/title，只归到它的第一个片段。
            final originals = matches
                .where((p) => !isMobiContinuation(p))
                .toList();
            return originals.length == 1 ? originals.single : entry.href;
          }(),
          // 同一文件既有卷题又有章题时，唯一的同名标题ID可恢复精确目标，
          // 避免“第一章”与Part卷题都落在文件顶部。已有锚点保持原样。
          fragment: entry.fragment?.isNotEmpty == true
              ? entry.fragment
              : _headingIds[entry.href]?[_key(entry.title)]?.length == 1
              ? _headingIds[entry.href]![_key(entry.title)]!.single
              : entry.fragment,
          children: recover(entry.children),
        ),
    ];
  }

  static String _key(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 阅读分段是内部读取单位，不能把后续片段当作新增章节。
bool isMobiContinuation(String path) {
  final match = RegExp(r'-s(\d{5})\.html$').firstMatch(path);
  return match != null && int.parse(match[1]!) > 0;
}
