import 'dart:math' as math;

import '../../../domain/models/book_document.dart';
import '../../../domain/models/pdf_page_info.dart';
import 'pdf_file.dart';
import 'pdf_visual_regions.dart';

/// 只补充当前电子书页的图片。文字块ID不变，书签与笔记不会因补图而错位。
/// 返回值进入现有可回收正文缓存；持久索引仍可从原PDF重建这些图片。
Future<ChapterContent> preparePdfPagePictures(
  PdfFile pdf,
  ChapterContent content,
) async {
  final info = content.pdfPage!;
  final page = pdf.document.pages[info.index];
  final regions = await pdfVisualRegions(page, await page.loadText());
  final blocks = [...content.blocks];
  final bounds = {...info.blocks};
  var number = 0;
  for (final box in regions) {
    final id = 'g${++number}';
    final next = blocks.indexWhere((b) {
      final at = bounds[b.id]!;
      return at[1] > box[1] && (at[0] - box[0]).abs() < .3;
    });
    bounds[id] = box;
    blocks.insert(
      next < 0 ? blocks.length : next,
      ContentBlock(
        id: id,
        kind: BlockKind.image,
        resourcePath: 'res/pdf/p${info.index}-$id.png',
        resourceWidth: math.max(1, (page.width * box[2] * 2).round()),
        resourceHeight: math.max(1, (page.height * box[3] * 2).round()),
      ),
    );
  }
  return ChapterContent(
    chapterId: content.chapterId,
    blocks: blocks,
    pdfPage: PdfPageInfo(
      index: info.index,
      width: info.width,
      height: info.height,
      blocks: bounds,
    ),
  );
}
