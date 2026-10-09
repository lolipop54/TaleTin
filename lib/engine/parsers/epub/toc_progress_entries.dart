import 'dart:isolate';

import '../../../domain/models/book_document.dart';
import '../../../domain/services/toc_entry_index.dart';
import '../../normalization/locator_mapper.dart';
import 'anchor_locator.dart';

/// 一个正文文件内的目录位置。EPUB 优先用原始锚点，标题仅用于缺失锚点的旧书。
/// 返回章内比例，调用方再转换为全书进度；不保留整章 DOM。
List<TocProgressEntry> chapterTocEntries({
  required String bookId,
  required int version,
  required Chapter chapter,
  required ChapterContent content,
  required List<TocTitleRef> titles,
  required bool isTxt,
  String? html,
}) {
  final map = html == null
      ? null
      : ChapterAnchorMap.parse(
          sanitizedHtml: html,
          resourceHref: chapter.href ?? '',
          bookId: bookId,
          contentVersion: version,
          chapterId: chapter.id,
        );
  Map<String, double> positions(List<ContentBlock> blocks) {
    final total = blocks.fold<int>(0, (n, block) => n + block.textLength);
    var offset = 0;
    final result = <String, double>{};
    for (final block in blocks) {
      result[block.id] = total == 0 ? 0 : offset / total;
      offset += block.textLength;
    }
    return result;
  }

  final offsets = positions(content.blocks);
  final anchorOffsets = map == null ? null : positions(map.blocks);
  final anchorLength =
      map?.blocks.fold<int>(0, (n, b) => n + b.textLength) ?? 0;
  final result = <TocProgressEntry>[];
  for (final title in titles) {
    final fragment = title.anchorId;
    double? fraction;
    if (!isTxt && (fragment == null || fragment.isEmpty)) {
      fraction = 0; // 无片段的 EPUB 链接指向文件首页，不按标题搜索。
    } else if (map != null && fragment != null) {
      final target = map.locatorOfAnchor(fragment);
      if (target != null) {
        fraction =
            anchorOffsets![target.blockId]! +
            (anchorLength == 0 ? 0 : target.utf16Offset / anchorLength);
      }
    }
    if (fraction == null) {
      for (final block in content.blocks) {
        final text = blockTextOf(block).trim();
        if (isTxt
            ? fragment != 'gt-txt:${block.id}'
            : block.kind != BlockKind.heading) {
          continue;
        }
        if (text == title.title ||
            (!isTxt && tocHeadingWithoutNumber(text) == title.title)) {
          fraction = offsets[block.id];
          break;
        }
      }
    }
    // 损坏锚点也保留目录项，跳转时仍由原有标题／章首降级逻辑处理。
    // 不能因为匹配不上就删掉条目，否则“下一章”会跨过大片正文。
    result.add((
      progress: fraction ?? (result.lastOrNull?.progress ?? 0),
      title: title.title,
      chapterId: chapter.id,
      anchorId: fragment,
    ));
  }
  return result;
}

/// 真实 EPUB 的 DOM 解析放到后台；纯文本目录直接使用已有正文，不增加线程等待。
Future<List<TocProgressEntry>> prepareChapterTocEntries({
  required String bookId, required int version, required Chapter chapter,
  required ChapterContent content, required List<TocTitleRef> titles,
  required bool isTxt, String? html,
}) async {
  List<TocProgressEntry> parse() => chapterTocEntries(bookId: bookId,
    version: version, chapter: chapter, content: content, titles: titles,
    isTxt: isTxt, html: html);
  return html == null ? parse() : Isolate.run(parse);
}
