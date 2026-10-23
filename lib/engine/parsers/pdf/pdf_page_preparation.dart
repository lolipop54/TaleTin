import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../../../domain/models/book_document.dart';
import '../../../domain/models/pdf_page_info.dart';
import '../../normalization/text_anchor.dart';
import 'pdf_text_blocks.dart';

typedef PdfPagePreparation = (
  PdfPageRawText?,
  double,
  double,
  int,
  List<List<double>>,
  String,
  int,
);
(Chapter, Map<String, List<int>>) preparePdfPage(PdfPagePreparation input) {
  final (raw, width, height, rotation, originalFigures, workDir, i) = input;
  var figures = originalFigures;
  final id = 'pdf-${i + 1}';
  final text = pdfTextBlocksFromGeometry(raw, width, height, rotation);
  final images = <String, List<int>>{};
  final count = text.fold<int>(0, (n, t) => n + t.text.length);
  final largeImage = figures.any((b) => b[2] * b[3] > .65);
  // 仅页码/水印有文字时，正文仍按扫描页保存；不把图片中的字当成可复制文字。
  final scan =
      count < 3 ||
      (largeImage &&
          count < 60 &&
          text.every((t) => t.box[1] < .12 || t.box[1] > .86));
  // 原页阅读不需要把整页背景拆图，首次电子书读到这一页才做。
  final pendingPictures = !scan && largeImage;
  if (pendingPictures) figures = [];
  final candidates = <({PdfTextBlock? text, List<double> box})>[];
  if (scan) {
    candidates.add((text: null, box: [0, 0, 1, 1]));
  } else {
    candidates.addAll(text.map((t) => (text: t, box: t.box)));
    for (final box in figures) {
      // 全页背景/已有OCR文字层不重复作为第二份正文贴图。
      if (box[2] * box[3] > .65) continue;
      final overlapsText = text.any(
        (t) => _overlap(box, t.box) > t.box[2] * t.box[3] * .5,
      );
      if (!overlapsText &&
          !candidates.any(
            (c) =>
                c.text == null && _overlap(c.box, box) > box[2] * box[3] * .85,
          )) {
        candidates.add((text: null, box: box));
      }
    }
    // 插图按所处阅读段落插入，保持文字候选已经确定的栏内顺序。
    final pictures = candidates.where((c) => c.text == null).toList();
    candidates.removeWhere((c) => c.text == null);
    for (final picture in pictures) {
      final next = candidates.indexWhere(
        (c) =>
            c.box[1] > picture.box[1] && (c.box[0] - picture.box[0]).abs() < .3,
      );
      candidates.insert(next < 0 ? candidates.length : next, picture);
    }
  }
  final blocks = <ContentBlock>[];
  final bounds = <String, List<double>>{};
  for (final candidate in candidates) {
    final blockId = 'b${blocks.length + 1}', box = candidate.box;
    bounds[blockId] = box;
    if (candidate.text case final t?) {
      blocks.add(
        ContentBlock(
          id: blockId,
          kind: BlockKind.paragraph,
          runs: [TextRun(t.text)],
        ),
      );
    } else {
      final path = 'pdf/p$i-$blockId.png';
      images[path] = [-1, -1];
      final imageWidth = math.max(1, (width * box[2] * 2).round());
      final imageHeight = math.max(1, (height * box[3] * 2).round());
      blocks.add(
        ContentBlock(
          id: blockId,
          kind: BlockKind.image,
          resourcePath: 'res/$path',
          resourceWidth: imageWidth,
          resourceHeight: imageHeight,
        ),
      );
    }
  }
  final content = ChapterContent(
    chapterId: id,
    blocks: blocks,
    pdfPage: PdfPageInfo(
      index: i,
      width: width,
      height: height,
      blocks: bounds,
      pendingPictures: pendingPictures,
    ),
  );
  final path = '$id.json';
  File(p.join(workDir, path)).writeAsBytesSync(content.encode());
  final chapter = Chapter(
    id: id,
    ordinal: i,
    title: '第${i + 1}页',
    contentPath: 'content/$kContentVersion/$path',
    textLength: content.textLength,
    href: 'pdf:$i',
  );
  return (chapter, images);
}

typedef PdfOutlinePreparation = (
  List<PdfOutlineNode>,
  List<Chapter>,
  List<double>,
  String,
  int,
);
(List<TocNode>, Map<String, Map<String, double?>>) preparePdfOutline(
  PdfOutlinePreparation input,
) {
  final (outline, chapters, heights, workDir, contentVersion) = input;
  final tocPositions = <String, Map<String, double?>>{};
  TocNode convert(PdfOutlineNode node) {
    final destination = node.dest;
    final index = destination == null ? -1 : destination.pageNumber - 1;
    var y = 0.0;
    if (index >= 0 && index < heights.length && destination != null) {
      final params = destination.params;
      final top = switch (destination.command) {
        PdfDestCommand.xyz =>
          params != null && params.length > 1 ? params[1] : null,
        PdfDestCommand.fitH || PdfDestCommand.fitBH => params?.firstOrNull,
        _ => null,
      };
      if (top != null) y = (1 - top / heights[index]).clamp(0.0, 1.0);
    }
    if (index >= 0 && index < heights.length) {
      final chapter = chapters[index];
      final content = ChapterContent.fromJson(
        (jsonDecode(
          File(p.join(workDir, '${chapter.id}.json')).readAsStringSync(),
        ) as Map).cast<String, Object?>(),
      );
      final anchor = content.pdfPage!.anchorAt(content, '', chapter.id, y);
      (tocPositions[chapter.id] ??= {})['pdf-y:$y'] = fractionOfLocator(
        content: content,
        bookId: '',
        contentVersion: contentVersion,
        chapterId: chapter.id,
        locator: anchor,
      );
    }
    return TocNode(
      title: node.title,
      chapterId: index >= 0 && index < heights.length
          ? chapters[index].id
          : null,
      fragment: 'pdf-y:$y',
      children: node.children.map(convert).toList(),
    );
  }

  return (outline.map(convert).toList(), tocPositions);
}

double _overlap(List<double> a, List<double> b) =>
    math.max(0.0, math.min(a[0] + a[2], b[0] + b[2]) - math.max(a[0], b[0])) *
    math.max(0.0, math.min(a[1] + a[3], b[1] + b[3]) - math.max(a[1], b[1]));
