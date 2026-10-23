import 'dart:isolate';

import '../../../core/diagnostics/reader_work_trace.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/services/toc_entry_index.dart';
import '../../normalization/locator_mapper.dart';
import 'anchor_locator.dart';
import 'xhtml_blocks.dart';

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
  Map<String, double?>? preparedAnchorPositions,
}) {
  final trace = ReaderWorkTrace.start('content.toc.entries', {
    'titles': titles.length,
    'hasHtml': html != null,
  });
  try {
    final nativePositions =
        preparedAnchorPositions ??
        (html == null
            ? null
            : XhtmlBlockBuilder.anchorPositions(
                html,
                chapter.href ?? '',
                titles.map((title) => title.anchorId).whereType<String>(),
              ));
    final map = html == null || nativePositions != null
        ? null
        : ChapterAnchorMap.parse(
            sanitizedHtml: html,
            resourceHref: chapter.href ?? '',
            bookId: bookId,
            contentVersion: version,
            chapterId: chapter.id,
          );
    trace?.mark('anchor_map');
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
    trace?.mark('offsets');
    for (final title in titles) {
      final fragment = title.anchorId;
      double? fraction;
      if (!isTxt && (fragment == null || fragment.isEmpty)) {
        fraction = 0; // 无片段的 EPUB 链接指向文件首页，不按标题搜索。
      } else if (nativePositions != null && fragment != null) {
        fraction = nativePositions[fragment];
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
    trace?.mark('find_titles');
    return result;
  } catch (error) {
    trace?.finish(status: error.runtimeType.toString());
    rethrow;
  } finally {
    trace?.finish();
  }
}

/// 真实 EPUB 的 DOM 解析放到后台；纯文本目录直接使用已有正文，不增加线程等待。
Future<List<TocProgressEntry>> prepareChapterTocEntries({
  required String bookId,
  required int version,
  required Chapter chapter,
  ChapterContent? content,
  Future<ChapterContent> Function()? readContent,
  required List<TocTitleRef> titles,
  required bool isTxt,
  String? html,
  Map<String, double?>? preparedAnchorPositions,
  Map<String, double>? preparedTitlePositions,
}) async {
  if (!isTxt &&
      preparedAnchorPositions != null &&
      (preparedTitlePositions != null ||
          titles.every(
            (title) =>
                title.anchorId == null ||
                title.anchorId!.isEmpty ||
                preparedAnchorPositions[title.anchorId] != null ||
                preparedTitlePositions?[title.title] != null,
          ))) {
    final entries = <TocProgressEntry>[];
    for (final title in titles) {
      final fraction = title.anchorId == null || title.anchorId!.isEmpty
          ? 0.0
          : preparedAnchorPositions[title.anchorId] ??
                preparedTitlePositions?[title.title] ??
                entries.lastOrNull?.progress ??
                0.0;
      entries.add((
        progress: fraction,
        title: title.title,
        chapterId: chapter.id,
        anchorId: title.anchorId,
      ));
    }
    return entries;
  }
  final body = content ?? await readContent!();
  List<TocProgressEntry> parse() => chapterTocEntries(
    bookId: bookId,
    version: version,
    chapter: chapter,
    content: body,
    titles: titles,
    isTxt: isTxt,
    html: html,
    preparedAnchorPositions: preparedAnchorPositions,
  );
  return html == null ? parse() : Isolate.run(parse);
}
