import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../epub/epub_archive.dart';
import '../epub/epub_package.dart';

/// 部分 KF8 合集的二进制导航仍引用合并前的文件编号，而正文目录中的链接
/// 提供完整目录名。只采用有明确目录标记的页面，再按真实标题核对链接。
List<RawTocEntry>? mobiHtmlToc(EpubArchive archive, EpubPackage package) {
  if (package.spine.firstOrNull?.entryPath != 'part00000.html') return null;
  final paths = package.navigationSpine.map((e) => e.entryPath).toList();
  final cache = <String, List<RawTocEntry>>{};
  List<RawTocEntry> read(String path) => cache.putIfAbsent(path, () {
    if (!archive.contains(path)) return const [];
    final text = archive.readText(path);
    // 快速排除普通正文，避免为每个候选再建立 DOM。
    if (!text.contains('sgc-toc-title') &&
        !RegExp(
          r'<title>\s*目录\s*</title>',
          caseSensitive: false,
        ).hasMatch(text)) {
      return const [];
    }
    return _parse(text, path);
  });

  final roots = read(paths.first);
  if (roots.isEmpty) return null;
  final indexes = {for (var i = 0; i < paths.length; i++) paths[i]: i};
  final result = <RawTocEntry>[];
  Map<String, List<(int, String?)>>? headings;
  for (var i = 0; i < roots.length; i++) {
    final root = roots[i];
    final start = indexes[root.href];
    final end = i + 1 < roots.length
        ? indexes[roots[i + 1].href]
        : paths.length;
    var children = root.children;
    if (start != null && end != null && end > start) {
      // 册首页之后可能先有多页版权和献词。只找本册范围里的独立目录页，
      // 不从普通正文抽链接，也不越过下一册边界。
      for (var at = start; at < end; at++) {
        final entries = read(paths[at]);
        if (entries.isNotEmpty) {
          children = entries;
          break;
        }
      }
      if (children.isNotEmpty) {
        children = _recoverTargets(
          headings ??= _readHeadings(archive, paths),
          paths,
          start,
          end,
          children,
        );
      }
    }
    result.add(
      RawTocEntry(
        title: root.title,
        href: root.href,
        fragment: root.fragment,
        children: children,
      ),
    );
  }
  return result;
}

String _headingKey(String title) =>
    title.replaceAll(RegExp(r'[\s，,：:·._\-！!？?（）()]'), '').toLowerCase();

/// 合集正文可能交错存放，不能用册首页之间的文件范围判定所有链接错误。
/// 先保留确实指向同名标题的源链接；其余按本册、全书唯一标题和父目录范围恢复。
/// 保留“一”“第一章”“1”的区别，避免把不同册的不同编号形式混为同一标题。
Map<String, List<(int, String?)>> _readHeadings(
  EpubArchive archive,
  List<String> paths,
) {
  final headings = <String, List<(int, String?)>>{};
  for (var at = 0; at < paths.length; at++) {
    final document = html.parse(archive.readText(paths[at]));
    if (document.querySelector('.sgc-toc-title') != null ||
        document.querySelector('title')?.text.trim() == '目录') {
      continue;
    }
    for (final h in document.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
      final key = _headingKey(h.text);
      if (key.isEmpty) continue;
      final anchor =
          h.attributes['id'] ??
          h.querySelector('a[id]')?.attributes['id'] ??
          h.querySelector('a[name]')?.attributes['name'];
      (headings[key] ??= []).add((at, anchor));
    }
  }
  return headings;
}

List<RawTocEntry> _recoverTargets(
  Map<String, List<(int, String?)>> headings,
  List<String> paths,
  int start,
  int end,
  List<RawTocEntry> entries,
) {
  (int, String?)? target(RawTocEntry n, int from, int to) {
    final candidates = headings[_headingKey(n.title)] ?? const [];
    // 有效源链接优先；仅补充同文件内明确的标题锚点。
    final original = candidates.where((h) => paths[h.$1] == n.href).toList();
    if (original.length == 1) return original.single;
    final local = candidates.where((h) => h.$1 >= from && h.$1 < to).toList();
    if (local.length == 1) return local.single;
    return candidates.length == 1 ? candidates.single : null;
  }

  List<RawTocEntry> recover(List<RawTocEntry> nodes, int from, int to) {
    final targets = [for (final n in nodes) target(n, from, to)];
    return [
      for (var i = 0; i < nodes.length; i++)
        () {
          final n = nodes[i], t = targets[i];
          final next = i + 1 < nodes.length ? targets[i + 1]?.$1 : null;
          final childFrom = t?.$1 ?? from;
          final childTo = next != null && next > childFrom ? next : to;
          return RawTocEntry(
            title: n.title,
            href: t == null ? n.href : paths[t.$1],
            fragment: t == null ? n.fragment : t.$2,
            children: recover(n.children, childFrom, childTo),
          );
        }(),
    ];
  }

  return recover(entries, start, end);
}

List<RawTocEntry> _parse(String source, String path) {
  final document = html.parse(source);
  final body = document.body;
  if (body == null) return const [];
  final grouped = <Element?, List<Element>>{};
  final links = body.querySelectorAll('a[href]');
  if (links.isEmpty) return const [];
  final marked = document.querySelector('.sgc-toc-title') != null;
  if (!marked) {
    int length(String text) => text.replaceAll(RegExp(r'\s+'), '').length;
    final linkedText = links.fold<int>(0, (n, a) => n + length(a.text));
    if (linkedText < length(body.text) * .7) return const [];
  }
  for (final a in links) {
    // 一个目录项可能是嵌套 div，也可能是 p/li；按真实父级链接保留层级。
    Element? parentLink;
    for (var p = a.parent; p != null && p != body; p = p.parent) {
      final direct = p.children.where((e) => e.localName == 'a').firstOrNull;
      if (direct != null && direct != a) {
        parentLink = direct;
        break;
      }
    }
    (grouped[parentLink] ??= []).add(a);
  }
  List<RawTocEntry> build(Element? parent) => [
    for (final a in grouped[parent] ?? const <Element>[])
      if (a.text.trim().isNotEmpty &&
          resolveEntryPath(path, a.attributes['href']!) != null)
        RawTocEntry(
          title: a.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
          href: resolveEntryPath(path, a.attributes['href']!),
          fragment: Uri.tryParse(a.attributes['href']!)?.fragment,
          children: build(a),
        ),
  ];
  return build(null);
}
