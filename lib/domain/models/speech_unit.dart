/// 送给 TTS 朗读的最小文本单元（离线听书实现计划 第 5、6 节）。
///
/// 「句」和「单元」不是一回事：一句话太长时会被拆成多个 unit 依次送给引擎，
/// 但它们共享同一个完整句范围——高亮永远按整句画，不按 unit 画，
/// 面板显示的也是整句而不是半个句子。
///
/// 所有偏移都是源文本的 UTF-16 code unit 偏移，且落在字素簇边界上；
/// [text] 必须等于源文本的对应片段（首尾空白可以不送引擎，此时
/// [startLocator] 指向真正开始朗读的那个字符）。补读的目录标题不属于正文，
/// 两端都使用真实章首位置，不把标题字数写入正文偏移。
library;

import 'locator.dart';

class SpeechUnit {
  const SpeechUnit({
    required this.id,
    required this.bookId,
    required this.contentVersion,
    required this.logicalChapterId,
    required this.text,
    required this.startLocator,
    required this.endLocator,
    required this.sentenceId,
    required this.sentenceText,
    required this.sentenceStart,
    required this.sentenceEnd,
  });

  /// 单元 ID，在一个逻辑章节内唯一（会话代号由控制器另加，见实现计划第 7 节）
  final String id;

  final String bookId;
  final int contentVersion;

  /// 所属逻辑章节的稳定 ID；一个逻辑章节可能跨多个正文文件
  final String logicalChapterId;

  /// 实际送给引擎的文本（不含首尾空白）
  final String text;

  /// 补读的目录章名使用零长度正文范围；普通正文单元总有实际文字范围。
  bool get isChapterTitle => startLocator.samePosition(endLocator);

  /// [text] 第一个字符的原文位置（右开区间的起点）
  final Locator startLocator;

  /// [text] 之后一个字符的原文位置（右开区间的终点，不包含）
  final Locator endLocator;

  /// 所属句子的 ID，同一句拆出的多个 unit 相同
  final String sentenceId;

  /// 整句原文：面板显示与高亮范围都用它
  final String sentenceText;

  /// 整句起点
  final Locator sentenceStart;

  /// 整句终点（右开区间）
  final Locator sentenceEnd;

  /// 本 unit 文本在整句中的起点（UTF-16）。
  ///
  /// 句子不跨块（块末就是自然句末，见实现计划 6.1），所以块内偏移相减即可。
  int get sentenceOffset =>
      startLocator.utf16Offset - sentenceStart.utf16Offset;

  /// 本 unit 是否是整句的第一个 unit（送引擎前用来决定要不要高亮新句）
  bool get isSentenceStart => sentenceOffset == 0;

  /// 本 unit 是否是整句的最后一个 unit（读完它才算这一句读完）
  bool get isSentenceEnd =>
      endLocator.utf16Offset == sentenceEnd.utf16Offset;

  /// 整句长度（UTF-16），与 [sentenceText].length 同源
  int get sentenceLength => sentenceText.length;

  @override
  String toString() => 'SpeechUnit($id'
      '${isSentenceStart ? '·句首' : '+$sentenceOffset'}'
      '/${sentenceText.length}'
      ' "${text.length > 12 ? '${text.substring(0, 12)}…' : text}")';
}
