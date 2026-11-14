import '../../domain/models/book_document.dart';

/// 兼容图片还独立分块时建立的章节索引，不修改显示文字、图片位置或块号。
///
/// 旧版在每张图片处结束文字块，会分别裁掉前后空格；行内合并后保留了
/// 这些空格。只有按这套明确的旧规则重算后整章长度完全一致，才采用旧权重。
/// 当前索引优先原样返回，其他长度错误仍交给读章入口报错。
ChapterContent matchInlineImageIndex(
  ChapterContent content,
  int expectedLength,
) {
  if (content.textLength == expectedLength) return content;
  var removed = 0;
  final weights = <int, int>{};
  for (var i = 0; i < content.blocks.length; i++) {
    final block = content.blocks[i];
    if (block.inlineImages.isEmpty) continue;
    final text = block.runs.map((run) => run.text).join();
    var start = 0, difference = 0;
    void countChunk(int end) {
      final chunk = text.substring(start, end);
      final trimmed = chunk.replaceAll(_edgeSpace, '');
      difference += chunk.length - trimmed.length;
      // 只含空白的图片间隔在旧版不产生文字块，也不占一个块的分隔权重。
      if (chunk.isNotEmpty && trimmed.isEmpty) difference++;
      start = end;
    }

    for (final image in block.inlineImages) {
      countChunk(image.offset);
    }
    countChunk(text.length);
    if (difference > 0) {
      weights[i] = block.textLength - difference;
      removed += difference;
    }
  }
  if (removed == 0 || content.textLength - removed != expectedLength) {
    return content;
  }
  return ChapterContent(
    chapterId: content.chapterId,
    blocks: [
      for (var i = 0; i < content.blocks.length; i++)
        if (weights[i] case final weight?)
          _withWeight(content.blocks[i], weight)
        else
          content.blocks[i],
    ],
    tables: content.tables,
    epubDetailsRevision: content.epubDetailsRevision,
    pdfPage: content.pdfPage,
    stylesJson: content.stylesJson,
    displaySourceJson: content.displaySourceJson,
  );
}

final _edgeSpace = RegExp(r'^[ \n]+|[ \n]+$');

// 只换进度权重，保留显示和 UTF-16 坐标；不经旧样式序列化，避免丢掉片段属性。
ContentBlock _withWeight(ContentBlock block, int weight) => ContentBlock(
  id: block.id,
  kind: block.kind,
  runs: block.runs,
  level: block.level,
  resourcePath: block.resourcePath,
  resourceWidth: block.resourceWidth,
  resourceHeight: block.resourceHeight,
  alt: block.alt,
  noteLink: block.noteLink,
  target: block.target,
  nest: block.nest,
  ordered: block.ordered,
  ordinal: block.ordinal,
  breaks: block.breaks,
  indents: block.indents,
  isQuoteContainer: block.isQuoteContainer,
  boxId: block.boxId,
  parentBox: block.parentBox,
  line: block.line,
  inlineImages: block.inlineImages,
  inlineBoxes: block.inlineBoxes,
  weight: weight,
  styleId: block.styleId,
);
