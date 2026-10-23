import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/io/source_digest.dart';
import '../../../core/io/source_fingerprint.dart';
import '../../../core/errors/import_error.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/models/source_content_index.dart';
import '../../../domain/services/book_parser.dart';
import 'pdf_file.dart';
import 'pdf_page_preparation.dart';
import '../../../core/concurrency/background_compute.dart';

/// PDF不做OCR：文字层转标准正文，无可用正文的页面生成一个整页图片块。
/// 每个物理页有稳定的内部章节ID；对用户显示的目录始终来自原文件大纲。
class PdfParser {
  const PdfParser();
  Future<BookDocument> parse(
    ParseRequest request, {
    required ParseProgress onProgress,
    ParseCover? onCover,
  }) async {
    final PdfFile pdf;
    try {
      pdf = await PdfFile.open(request.sourcePath);
    } catch (error) {
      throw ImportFailure(
        ImportErrorCode.invalidContainer,
        'PDF无法打开，文件可能已损坏或需要密码：$error',
      );
    }
    try {
      final pages = pdf.document.pages;
      if (pages.isEmpty) throw const FormatException('PDF没有可阅读页面');
      if (pages.length > 20000) throw const FormatException('PDF页数超过20000页');
      await Directory(request.workDir).create(recursive: true);
      final cover = await pdf.render(0, 360);
      final coverFile = File(p.join(request.workDir, 'res', 'cover.png'));
      await coverFile.parent.create(recursive: true);
      await coverFile.writeAsBytes(cover);
      onCover?.call(cover);
      final chapters = <Chapter>[];
      final locations = <String, List<Object>>{};
      final images = <String, List<int>>{};
      for (var i = 0; i < pages.length; i++) {
        final page = pages[i], id = 'pdf-${i + 1}';
        final raw = await page.loadText();
        final figures = await pdf.illustrations(i);
        final (chapter, pageImages) = await backgroundCompute(preparePdfPage, (
          raw,
          page.width,
          page.height,
          page.rotation.index,
          figures,
          request.workDir,
          i,
        ));
        chapters.add(chapter);
        images.addAll(pageImages);
        locations[id] = [i];
        onProgress((i + 1) / pages.length);
      }
      final outline = await pdf.document.loadOutline();
      final (toc, tocPositions) = await backgroundCompute(preparePdfOutline, (
        outline,
        chapters,
        [for (final page in pages) page.height],
        request.workDir,
        request.contentVersion,
      ));
      final stat = File(request.sourcePath).statSync();
      return BookDocument(
        title: p.basenameWithoutExtension(request.displayName),
        author: '',
        chapters: chapters,
        toc: toc,
        tocRevision: kTocRevision,
        coverPath: 'res/cover.png',
        coverWidth: 360,
        coverHeight: (360 * pages.first.height / pages.first.width).round(),
        sourceIndex: SourceContentIndex(
          format: 'pdf',
          sourceDigest: await backgroundCompute(
            sourceFileDigest,
            request.sourcePath,
          ),
          sourceBytes: stat.size,
          sourceStamp: sourceFingerprint(stat),
          chapters: locations,
          images: images,
          tocPositions: tocPositions,
        ),
      );
    } finally {
      await pdf.close();
    }
  }
}
