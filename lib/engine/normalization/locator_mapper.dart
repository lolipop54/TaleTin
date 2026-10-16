/// 标准化正文 ↔ [Locator] 的换算（设计文档 6.3）。
///
/// 分页、翻页、书签、笔记都通过这一层说话，上层不直接碰文本偏移的细节：
/// - 偏移一律是**标准化文本**上的 UTF-16 code unit 偏移，与 Flutter 文本 API 对齐；
/// - 有效边界必须落在字素簇边界，不拆 emoji 与代理对；
/// - 生成 Locator 时顺带存一小段摘录与前后文，供正文版本变化后重新定位。
library;

import 'package:characters/characters.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';

/// 一个块在标准化文本上的纯文本内容。
///
/// 内联样式（加粗/斜体）不影响偏移，只影响绘制，因此这里按 run 顺序直接拼接。
String blockTextOf(ContentBlock block) {
  if (block.runs.length == 1) return block.runs.first.text;
  final buffer = StringBuffer();
  for (final run in block.runs) {
    buffer.write(run.text);
  }
  return buffer.toString();
}

/// 把任意偏移夹到字素簇边界（向前对齐）。
///
/// 分页切分点来自 [TextPainter] 的行起点，本身已经在字素簇边界上；
/// 这里是兜底，避免选区、目录跳转等外部来源给出半个 emoji。
int snapToGrapheme(String text, int offset) {
  if (offset <= 0) return 0;
  if (offset >= text.length) return text.length;
  var index = 0;
  for (final cluster in text.characters) {
    final next = index + cluster.length;
    if (next > offset) return index;
    index = next;
  }
  return text.length;
}

/// 生成/解析 Locator 的工具。
///
/// 每次排版用同一个实例；它只持有 bookId、正文版本和章节 ID 这类上下文。
class LocatorMapper {
  const LocatorMapper({
    required this.bookId,
    required this.contentVersion,
    required this.chapterId,
  });

  final String bookId;
  final int contentVersion;
  final String chapterId;

  /// 在 [block] 的 [offset] 处生成锚点，顺带存摘录与前后文。
  Locator at(ContentBlock block, int offset, {LocatorAffinity? affinity}) {
    final text = blockTextOf(block);
    final safe = snapToGrapheme(text, offset);
    return Locator(
      bookId: bookId,
      contentVersion: contentVersion,
      chapterId: chapterId,
      blockId: block.id,
      utf16Offset: safe,
      // 图片块由调用方给出 before/after，文本块一律用 center
      affinity: affinity ?? LocatorAffinity.center,
      exact: _slice(text, safe, safe + kLocatorExactLimit),
      prefix: _slice(text, safe - kLocatorContextLimit, safe),
      suffix: _slice(text, safe, safe + kLocatorContextLimit),
      imageResource: block.kind == BlockKind.image ? block.resourcePath : null,
    );
  }

  /// 章首锚点：第一章第一块的开头，用于「没有历史进度」时的落点。
  Locator chapterStart(List<ContentBlock> blocks) {
    if (blocks.isEmpty) {
      return Locator(
        bookId: bookId,
        contentVersion: contentVersion,
        chapterId: chapterId,
        blockId: '',
        utf16Offset: 0,
      );
    }
    return at(blocks.first, 0);
  }

  /// 章节内文本总长度，口径与 `ChapterContent.textLength` 一致
  /// （每块额外计 1，让图片、分隔线这类空块也有位置权重），
  /// 这样章内百分比与全书百分比的分母是同一套算法。
  int totalLength(List<ContentBlock> blocks) {
    var total = 0;
    for (final block in blocks) {
      total += blockTextOf(block).length + 1;
    }
    return total;
  }

  /// 偏移截取：越界部分自动收窄，不抛异常。
  static String _slice(String text, int start, int end) {
    final from = start.clamp(0, text.length);
    final to = end.clamp(from, text.length);
    return text.substring(from, to);
  }
}
