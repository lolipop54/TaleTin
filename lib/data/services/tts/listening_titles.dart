import '../../../domain/models/book_document.dart';
import '../../../domain/models/speech_unit.dart';
import '../../../engine/normalization/locator_mapper.dart';
import '../../../engine/normalization/speech_unit_builder.dart';
import 'listening_chapter_targets.dart';

/// TXT 章名只存于目录；缺少正文标题时补读，位置始终停在真实章首。
List<SpeechUnit> addListeningTitles(
  List<SpeechUnit> units,
  ChapterContent content,
  List<ListeningTarget> targets,
  int maxLength,
) {
  final result = <SpeechUnit>[];
  final compare = fileLocationComparator(content);
  final blocks = {for (final block in content.blocks) block.id: block};
  var targetIndex = 0;
  var previousChapter = '';
  for (final unit in units) {
    while (targetIndex < targets.length &&
        compare(targets[targetIndex].start, unit.startLocator) <= 0) {
      targetIndex++;
    }
    if (unit.logicalChapterId != previousChapter && targetIndex > 0) {
      final target = targets[targetIndex - 1];
      final block = blocks[unit.startLocator.blockId]!;
      final title = target.chapter.title.trim();
      final firstText = blockTextOf(block)
          .substring(unit.startLocator.utf16Offset);
      // EPUB 的语义标题直接读原文；普通段落中的同名章题也不能读两遍。
      if (target.chapter.id == unit.logicalChapterId &&
          !target.chapter.isPreamble &&
          title.isNotEmpty &&
          block.kind != BlockKind.heading &&
          _titleKey(firstText) != _titleKey(title)) {
        for (final (i, piece) in splitLongSentence(title, maxLength).indexed) {
          result.add(
            SpeechUnit(
              id: 'title:${target.chapter.id}:$i',
              bookId: unit.bookId,
              contentVersion: unit.contentVersion,
              logicalChapterId: unit.logicalChapterId,
              text: title.substring(piece.start, piece.end),
              startLocator: target.start,
              endLocator: target.start,
              sentenceId: 'title:${target.chapter.id}',
              sentenceText: title,
              sentenceStart: target.start,
              sentenceEnd: target.start,
            ),
          );
        }
      }
    }
    previousChapter = unit.logicalChapterId;
    result.add(unit);
  }
  return result;
}

String _titleKey(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').toLowerCase();
