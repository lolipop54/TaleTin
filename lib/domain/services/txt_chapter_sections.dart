import '../models/book_document.dart';
import '../models/source_content_index.dart';

/// TXT 以原段落为界分组。字数包含每个段落的一个位置权重。
class TxtChapterSections {
  TxtChapterSections(
    Iterable<int> paragraphLengths, {
    int target = targetLength,
  }) {
    var paragraph = 0, offset = 0, nextOffset = 0;
    for (final length in paragraphLengths) {
      if (offset >= nextOffset) {
        starts.add((paragraph: paragraph, offset: offset));
        nextOffset = offset + target;
      }
      paragraph++;
      offset += length;
    }
    paragraphCount = paragraph;
    textLength = offset;
  }

  static const targetLength = 8000;
  static int nextStartAfter(int offset) => offset + targetLength;
  static const anchorPrefix = 'gt-txt-section:';
  final starts = <({int paragraph, int offset})>[];
  late final int paragraphCount, textLength;

  static String anchorFor(String blockId) => '$anchorPrefix$blockId';

  static String? blockOfAnchor(String? anchor) =>
      anchor != null && anchor.startsWith(anchorPrefix)
      ? anchor.substring(anchorPrefix.length)
      : null;

  static List<TxtTocSection> tocOf(ChapterContent content) {
    final sections = TxtChapterSections(
      content.blocks.map((b) => b.textLength),
    );
    return [
      if (sections.starts.length > 1)
        for (final start in sections.starts)
          (blockId: content.blocks[start.paragraph].id, offset: start.offset),
    ];
  }

  int containingParagraph(int paragraph) {
    var first = 0, last = starts.length - 1;
    while (first < last) {
      final middle = (first + last + 1) ~/ 2;
      if (starts[middle].paragraph <= paragraph) {
        first = middle;
      } else {
        last = middle - 1;
      }
    }
    return first;
  }
}

/// 目录只需要真实块号和分节起始位置，不复制正文。
typedef TxtTocSection = ({String blockId, int offset});

/// 核对过的来源索引与按节读取入口。正文段落仍使用整章里的编号。
class TxtChapterSource {
  const TxtChapterSource({
    required this.identity,
    required this.starts,
    required this.readSection,
  });

  final String identity;
  final List<TxtSectionStart> starts;
  final Future<ChapterContent> Function(int section) readSection;

  static int? paragraphOf(String blockId) {
    if (!blockId.startsWith('b')) return null;
    final number = int.tryParse(blockId.substring(1));
    return number == null || number < 1 ? null : number - 1;
  }

  int forParagraph(int paragraph) =>
      _find(paragraph, (start) => start.paragraph);
  int forOffset(int offset) => _find(offset, (start) => start.textOffset);

  int _find(int value, int Function(TxtSectionStart) position) {
    var first = 0, last = starts.length - 1;
    while (first < last) {
      final middle = (first + last + 1) ~/ 2;
      if (position(starts[middle]) <= value) {
        first = middle;
      } else {
        last = middle - 1;
      }
    }
    return first;
  }
}
