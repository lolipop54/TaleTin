import '../../../domain/models/book_document.dart';
import '../../../domain/models/locator.dart';
import '../../../domain/models/speech_unit.dart';
import '../../../domain/services/logical_chapter_index.dart';
import '../../../engine/normalization/locator_mapper.dart';
import '../../../engine/parsers/epub/anchor_locator.dart';

typedef ListeningTarget = ({LogicalChapter chapter, Locator start});

/// 使用同一遍 DOM 解析得到的锚点；旧书先核对块文本，不能覆盖旧正文。
List<ListeningTarget> resolveListeningTargets({
  required String bookId,
  required int version,
  required Chapter file,
  required ChapterContent content,
  required List<LogicalChapter> entries,
  String? html,
}) {
  final mapper = LocatorMapper(
    bookId: bookId,
    contentVersion: version,
    chapterId: file.id,
  );
  ChapterAnchorMap? map;
  if (entries.any((entry) => entry.fragment != null && !entry.fragment!.startsWith('gt-txt:'))) {
    if (html == null) throw StateError('无法读取章节锚点：${file.title}');
    map = ChapterAnchorMap.parse(
      sanitizedHtml: html,
      resourceHref: file.href ?? '',
      bookId: bookId,
      contentVersion: version,
      chapterId: file.id,
    );
    if (map.blocks.length != content.blocks.length ||
        map.blocks.indexed.any(
          (pair) =>
              blockTextOf(pair.$2) != blockTextOf(content.blocks[pair.$1]),
        )) {
      throw StateError('正文与锚点对照不一致：${file.title}');
    }
  }
  final result = <ListeningTarget>[];
  for (final entry in entries) {
    Locator? start;
    if (entry.fragment == null) {
      start = mapper.chapterStart(content.blocks);
    } else if (entry.fragment!.startsWith('gt-txt:')) {
      // TXT 旧目录的补充章题使用原块 ID，不需要 EPUB 的 DOM。
      final id = entry.fragment!.substring('gt-txt:'.length);
      final block = content.blocks.where((block) => block.id == id).firstOrNull;
      if (block != null) start = mapper.at(block, 0);
    } else {
      final fragment = Uri.decodeComponent(entry.fragment!);
      start = map!.locatorOfAnchor(fragment);
      if (start != null) {
        // 旧正文的块 ID 可能不同，文本与顺序已核对，按顺序还原旧 ID。
        final index = map.blocks.indexWhere((b) => b.id == start!.blockId);
        start = mapper.at(content.blocks[index], start.utf16Offset);
      } else {
        final exists =
            map.document.getElementById(fragment) != null ||
            map.document
                .querySelectorAll('a[name]')
                .any((e) => e.attributes['name'] == fragment);
        if (exists) {
          // 锚点存在但后面已无文字，属于空范围，落到文件末端并继续找下一章。
          start = content.blocks.isEmpty
              ? mapper.chapterStart(const [])
              : mapper.at(
                  content.blocks.last,
                  blockTextOf(content.blocks.last).length,
                );
        } else {
          final matches = content.blocks
              .where(
                (block) =>
                    block.kind == BlockKind.heading &&
                    blockTextOf(block).trim() == entry.title.trim(),
              )
              .toList();
          if (matches.length == 1) start = mapper.at(matches.single, 0);
        }
      }
    }
    if (start == null) throw StateError('目录条目无法唯一定位：${entry.title}');
    result.add((chapter: entry, start: start));
  }
  final compare = fileLocationComparator(content);
  result.sort((a, b) => compare(a.start, b.start));
  return result;
}

List<ListeningTarget> uniqueListeningTargets(List<ListeningTarget> targets) {
  // 卷首范围与第一条锚点可能重合，空范围只保留真实目录条目。
  final unique = <ListeningTarget>[];
  for (final target in targets) {
    if (unique.isNotEmpty && unique.last.start.samePosition(target.start)) {
      if (unique.last.chapter.isPreamble) unique[unique.length - 1] = target;
    } else {
      unique.add(target);
    }
  }
  return unique;
}

int Function(Locator, Locator) fileLocationComparator(ChapterContent content) {
  final order = {for (final (i, block) in content.blocks.indexed) block.id: i};
  return (a, b) {
    final ai = order[a.blockId] ?? -1;
    final bi = order[b.blockId] ?? -1;
    return ai == bi ? a.utf16Offset - b.utf16Offset : ai - bi;
  };
}

/// 锚点可能在句子中间：切开 unit，防止旧章多读、跳章漏读。
List<SpeechUnit> assignLogicalChapters(
  List<SpeechUnit> units,
  ChapterContent content,
  List<ListeningTarget> targets,
  String initialChapterId,
) {
  final result = <SpeechUnit>[];
  var targetIndex = 0;
  var chapterId = initialChapterId;
  final compare = fileLocationComparator(content);
  final blocks = {for (final block in content.blocks) block.id: block};
  final targetsByBlock = <String, List<ListeningTarget>>{};
  for (final target in targets) {
    targetsByBlock.putIfAbsent(target.start.blockId, () => []).add(target);
  }
  for (final unit in units) {
    final mapper = LocatorMapper(
      bookId: unit.bookId,
      contentVersion: unit.contentVersion,
      chapterId: content.chapterId,
    );
    final block = blocks[unit.startLocator.blockId]!;
    final cuts = <int>[unit.startLocator.utf16Offset];
    for (final target in targetsByBlock[block.id] ?? <ListeningTarget>[]) {
      if (target.start.blockId == unit.startLocator.blockId &&
          target.start.utf16Offset > cuts.first &&
          target.start.utf16Offset < unit.endLocator.utf16Offset) {
        cuts.add(target.start.utf16Offset);
      }
    }
    cuts.add(unit.endLocator.utf16Offset);
    for (var i = 0; i + 1 < cuts.length; i++) {
      final start = mapper.at(block, cuts[i]);
      while (targetIndex < targets.length &&
          compare(targets[targetIndex].start, start) <= 0) {
        chapterId = targets[targetIndex++].chapter.id;
      }
      final end = mapper.at(block, cuts[i + 1]);
      var sentenceStart = unit.sentenceStart;
      var sentenceEnd = unit.sentenceEnd;
      if (targetIndex > 0 &&
          compare(targets[targetIndex - 1].start, sentenceStart) > 0) {
        sentenceStart = targets[targetIndex - 1].start;
      }
      if (targetIndex < targets.length &&
          compare(targets[targetIndex].start, sentenceEnd) < 0) {
        sentenceEnd = targets[targetIndex].start;
      }
      final sentenceText = blockTextOf(block)
          .substring(sentenceStart.utf16Offset, sentenceEnd.utf16Offset);
      final text = unit.text.substring(
        cuts[i] - unit.startLocator.utf16Offset,
        cuts[i + 1] - unit.startLocator.utf16Offset,
      );
      result.add(
        SpeechUnit(
          id: '${unit.id}.$i',
          bookId: unit.bookId,
          contentVersion: unit.contentVersion,
          logicalChapterId: chapterId,
          text: text,
          startLocator: start,
          endLocator: end,
          sentenceId: '${unit.sentenceId}:$chapterId',
          sentenceText: sentenceText,
          sentenceStart: sentenceStart,
          sentenceEnd: sentenceEnd,
        ),
      );
    }
  }
  return result;
}
