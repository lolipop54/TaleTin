import '../../../domain/models/locator.dart';
import '../../../domain/models/speech_unit.dart';
import '../../../engine/normalization/locator_mapper.dart';

/// 一个朗读单元按可见页首拆分后的结果。
///
/// [tail] 为空表示当前单元没有命中有效页边界。
class ListeningPageSplit {
  const ListeningPageSplit(this.head, this.tail);

  final SpeechUnit head;
  final SpeechUnit? tail;
}

/// 在当前朗读单元内最早的可见页首处拆分，且不会切开 emoji 等字素簇。
///
/// 此函数只计算结果，不修改播放队列；队列顺序仍由 [ListeningController]
/// 统一维护。
ListeningPageSplit splitSpeechUnitAtPage(
  SpeechUnit unit,
  List<Locator> pageBoundaries,
) {
  if (unit.isChapterTitle) return ListeningPageSplit(unit, null);
  var offset = unit.text.length;
  for (final point in pageBoundaries) {
    if (point.bookId != unit.bookId ||
        point.contentVersion != unit.contentVersion ||
        point.chapterId != unit.startLocator.chapterId ||
        point.blockId != unit.startLocator.blockId) {
      continue;
    }
    final delta = point.utf16Offset - unit.startLocator.utf16Offset;
    if (delta > 0 && delta < offset) offset = delta;
  }
  offset = snapToGrapheme(unit.text, offset);
  if (offset <= 0 || offset >= unit.text.length) {
    return ListeningPageSplit(unit, null);
  }
  final boundary = unit.startLocator.copyWith(
    utf16Offset: unit.startLocator.utf16Offset + offset,
  );
  SpeechUnit part({required bool tail}) => SpeechUnit(
    id: '${unit.id}:${tail ? offset : 0}',
    bookId: unit.bookId,
    contentVersion: unit.contentVersion,
    logicalChapterId: unit.logicalChapterId,
    text: tail ? unit.text.substring(offset) : unit.text.substring(0, offset),
    startLocator: tail ? boundary : unit.startLocator,
    endLocator: tail ? unit.endLocator : boundary,
    sentenceId: unit.sentenceId,
    sentenceText: unit.sentenceText,
    sentenceStart: unit.sentenceStart,
    sentenceEnd: unit.sentenceEnd,
  );
  return ListeningPageSplit(part(tail: false), part(tail: true));
}
