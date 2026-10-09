import '../models/locator.dart';
import '../models/speech_unit.dart';
import 'logical_chapter_index.dart';

/// 一个有限播放窗口。next 是未提交的下一段起点，null 表示书末。
class SpeechWindow {
  SpeechWindow(Iterable<SpeechUnit> units, this.next)
    : units = List.unmodifiable(units);
  final List<SpeechUnit> units;
  final Locator? next;
}

abstract class ListeningSource {
  Future<ListeningBook> open(String bookId, int contentVersion);
}

/// 每次打开独立的读正文会话，旧请求不能改动新会话的目录或队列。
abstract class ListeningBook {
  String get title;
  List<LogicalChapter> get chapters;
  Future<SpeechWindow> window(
    Locator from, {
    required bool sentenceStart,
    required int maxLength,
  });
  Future<Locator> chapterStart(String logicalChapterId);
  Future<void> close();
}
