import 'package:mobi_native/mobi_native.dart';
import 'package:xml/xml.dart';

import '../../../domain/models/book_document.dart';
import '../epub/epub_archive.dart';
import '../epub/epub_package.dart';

typedef _Target = (String href, String fragment, String oldTitle);

/// 只把原书索引里的标题补到已有目录。先按 NCX 节点 ID 找标题，再沿用保存的地址。
class MobiTocTitleRepair {
  MobiTocTitleRepair._(this._titles);

  final Map<_Target, List<String>> _titles;

  static MobiTocTitleRepair? read(String sourcePath, EpubArchive archive) {
    final package = EpubPackage.parse(
      archive,
      EpubPackage.readOpfPath(archive),
    );
    final ncx = package.ncxItem?.entryPath;
    if (ncx == null || !archive.contains(ncx)) return null;
    final native = DirectMobi(sourcePath);
    final String? xml;
    try {
      xml = native.readNavigationTitles();
    } finally {
      native.close();
    }
    if (xml == null) return null;

    final original = _points(archive.readText(ncx));
    final corrected = _points(xml);
    final paths = {for (final item in package.spine) item.entryPath: item.href};
    final titles = <_Target, List<String>>{};
    var changed = false;
    for (final entry in original.entries) {
      final old = _title(entry.value), title = _title(corrected[entry.key]);
      final target = _child(entry.value, 'content')?.getAttribute('src');
      if (old.isEmpty || title.isEmpty || target == null) continue;
      final href = paths[resolveEntryPath(ncx, target)];
      if (href == null) continue;
      final key = (href, Uri.tryParse(target)?.fragment ?? '', old);
      (titles[key] ??= []).add(title);
      changed |= title != old;
    }
    return changed ? MobiTocTitleRepair._(titles) : null;
  }

  List<TocNode> apply(List<TocNode> toc, List<Chapter> chapters) {
    final hrefs = {for (final chapter in chapters) chapter.id: chapter.href};
    _Target? key(TocNode node) {
      final href = hrefs[node.chapterId];
      return href == null ? null : (href, node.fragment ?? '', node.title);
    }

    // 同名同位置的多个原目录项，只有存下来的数量也相同时才按原顺序配对。
    final ambiguous = <_Target>{
      for (final e in _titles.entries)
        if (e.value.any((title) => title != e.value.first)) e.key,
    };
    final matchingCounts = <_Target, int>{}, seen = <_Target, int>{};
    void count(List<TocNode> nodes) {
      for (final node in nodes) {
        final target = key(node);
        if (target != null && ambiguous.contains(target)) {
          matchingCounts.update(target, (n) => n + 1, ifAbsent: () => 1);
        }
        count(node.children);
      }
    }

    if (ambiguous.isNotEmpty) count(toc);
    String titleOf(TocNode node) {
      final target = key(node);
      final choices = _titles[target];
      if (choices == null) return node.title;
      if (!ambiguous.contains(target)) return choices.first;
      if (matchingCounts[target] != choices.length) return node.title;
      return choices[seen.update(target!, (n) => n + 1, ifAbsent: () => 1) - 1];
    }

    TocNode repair(TocNode node) => TocNode(
      title: titleOf(node),
      chapterId: node.chapterId,
      fragment: node.fragment,
      children: [for (final child in node.children) repair(child)],
    );
    return [for (final node in toc) repair(node)];
  }

  static Map<String, XmlElement> _points(String xml) => {
    for (final element in XmlDocument.parse(xml).descendantElements)
      if (element.name.local == 'navPoint')
        ?element.getAttribute('id'): element,
  };

  static XmlElement? _child(XmlElement? node, String name) =>
      node?.childElements.where((e) => e.name.local == name).firstOrNull;

  static String _title(XmlElement? point) => cleanPublicationTocTitle(
    _child(_child(point, 'navLabel'), 'text')?.innerText ?? '',
  );
}
