import '../../domain/models/book_document.dart';
import '../../domain/models/book_search.dart';
import '../../domain/models/locator.dart';
import '../normalization/locator_mapper.dart';
import 'search_text.dart';

/// 搜索只拼真实文本块，以换行保留段落边界，不加入装饰章题或图片替代文字。
class SearchChapter {
  SearchChapter(this.content) {
    final buffer = StringBuffer();
    for (final block in content.blocks) {
      final text = blockTextOf(block);
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      blocks.add(block);
      positions.add(buffer.length);
      buffer.write(text);
    }
    source = buffer.toString();
  }
  final ChapterContent content;
  final blocks = <ContentBlock>[];
  final positions = <int>[];
  late final String source;
  // 无命中章节只做字符串比较，不为每个字建立原文位置数组。
  late final String searchText = source.toLowerCase().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );
  late final SearchText normalized = SearchText(source);

  Locator _locator(LocatorMapper mapper, int raw, {bool end = false}) {
    // 段间的插入换行只参与搜索；端点仍回到真实正文块。
    var index = positions.lastIndexWhere((p) => p <= raw);
    if (end && index > 0 && raw == positions[index]) index--;
    final block = blocks[index];
    return mapper.at(
      block,
      (raw - positions[index]).clamp(0, blockTextOf(block).length),
    );
  }

  BookSearchHit hit(
    String bookId,
    int version,
    String title,
    int at,
    int length,
  ) {
    final from = normalized.starts[at], to = normalized.ends[at + length - 1];
    final left = snapToGrapheme(source, (from - 40).clamp(0, source.length));
    var right = snapToGrapheme(source, (to + 40).clamp(0, source.length));
    if (right < to) right = to;
    final mapper = LocatorMapper(
      bookId: bookId,
      contentVersion: version,
      chapterId: content.chapterId,
    );
    return BookSearchHit(
      range: SelectionRange(
        start: _locator(mapper, from),
        end: _locator(mapper, to, end: true),
      ),
      chapterTitle: title,
      context: source.substring(left, right),
      matchStart: from - left,
      matchEnd: to - left,
    );
  }
}
