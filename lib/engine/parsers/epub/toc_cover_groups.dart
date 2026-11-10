import '../../../domain/models/book_document.dart';
import 'toc_target_recovery.dart';
import 'epub_archive.dart';
import 'epub_package.dart';
import 'xhtml_blocks.dart';

/// 封面即使标成辅助页，仍是目录中的分册起点，边界落在它后面的首个正文。
/// 新导入复用已经统计过的纯图片信息；旧书只读可能成为册首页的文档。
Map<String, int> tocBookCoverBoundaries(
  EpubArchive archive,
  EpubPackage package,
  List<RawTocEntry> raw,
  Map<String, String> chapterIds,
  List<Chapter> chapters, {
  Set<String>? knownCoverPaths,
}) {
  if (raw.any((n) => n.children.isNotEmpty)) return const {};
  final indexes = {for (var i = 0; i < chapters.length; i++) chapters[i].id: i};
  final starts = <String, int>{};
  var next = chapters.length;
  for (final item in package.navigationSpine.reversed) {
    next = indexes[chapterIds[item.entryPath]] ?? next;
    starts[item.entryPath] = next;
  }
  final result = <String, int>{};
  for (var i = 0; i < raw.length; i++) {
    final node = raw[i], path = node.href;
    final start = starts[path];
    final end = i + 1 < raw.length ? starts[raw[i + 1].href] : chapters.length;
    if (path == null ||
        start == null ||
        end == null ||
        (node.fragment?.isNotEmpty ?? false) ||
        end <= start + (chapterIds.containsKey(path) ? 1 : 0)) {
      continue;
    }
    var isCover = knownCoverPaths?.contains(path) ?? false;
    if (knownCoverPaths == null || !chapterIds.containsKey(path)) {
      final parsed = XhtmlBlockBuilder(
        basePath: path,
        buildTextMap: false,
        statisticsOnly: true,
        resolveImage: (p) => archive.contains(p)
            ? ResolvedImage(resourcePath: 'res/$p', width: -1, height: -1)
            : null,
      ).convertBytes(archive.readBytes(path));
      isCover = parsed.singleImagePath != null;
    }
    if (isCover) result[path] = start;
  }
  return result;
}

/// 合集的总目录可能只列册名，每册落在自己的纯图片封面上。
/// 封面到下一个目录项之间确实还有未列出的正文，才补成分册；
/// 普通章节漏列、重复封面及内部读取续段都不能单凭文件数量造分组。
List<TocNode> groupTocBookCovers(
  List<TocNode> nodes,
  List<Chapter> chapters,
  Map<TocNode, int> coverBoundaries,
) {
  if (coverBoundaries.isEmpty || nodes.any((n) => n.children.isNotEmpty)) {
    return nodes;
  }
  final indexById = {
    for (var i = 0; i < chapters.length; i++) chapters[i].id: i,
  };
  final starts = [
    for (final node in nodes)
      coverBoundaries[node] ?? indexById[node.chapterId],
  ];
  // 同文件多锚点与尚未确认的错误地址继续保留原结构，不拿作册边界。
  for (var i = 0; i < starts.length; i++) {
    if (starts[i] == null || (i > 0 && starts[i]! <= starts[i - 1]!)) {
      return nodes;
    }
  }
  final explicitIds = {for (final node in nodes) node.chapterId};
  return [
    for (var i = 0; i < nodes.length; i++)
      () {
        final node = nodes[i];
        final start = starts[i]!;
        final end = i + 1 < nodes.length ? starts[i + 1]! : chapters.length;
        if (!coverBoundaries.containsKey(node) ||
            (node.fragment?.isNotEmpty ?? false) ||
            const {'封面', 'cover'}.contains(node.title.trim().toLowerCase())) {
          return node;
        }
        final children = [
          if (node.chapterId != null) node,
          for (
            var at = start + (node.chapterId == null ? 0 : 1);
            at < end;
            at++
          )
            if (chapters[at].title.trim().isNotEmpty &&
                (!isMobiContinuation(chapters[at].href ?? '') ||
                    explicitIds.contains(chapters[at].id)))
              TocNode(title: chapters[at].title, chapterId: chapters[at].id),
        ];
        return children.length > (node.chapterId == null ? 0 : 1)
            ? TocNode(title: node.title, children: children)
            : node;
      }(),
  ];
}
