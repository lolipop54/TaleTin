import 'dart:io';

import 'package:mobi_native/mobi_native.dart';
import 'package:path/path.dart' as p;

import '../../../core/errors/import_error.dart';
import '../../../core/diagnostics/import_timing.dart';
import '../../../core/io/source_digest.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/services/book_parser.dart';
import '../epub/epub_parser.dart';
import '../epub/epub_archive.dart';
import 'mobi_publication.dart';
import 'mobi_source.dart';

/// 只负责还原 MOBI 容器。两种排版共用后续 HTML 转换及位置生成规则。
class MobiParser {
  const MobiParser();

  /// Build compact recipes; the standard EPUB pipeline still owns body rules,
  /// complete statistics, TOC generation and location matching.
  Future<BookDocument> parseDirect(
    ParseRequest request, {
    required ParseProgress onProgress,
    required bool Function() isCancelled,
    ParseCover? onCover,
  }) async {
    final timing = traceImportPerf ? ImportTiming('mobi_direct') : null;
    MobiPublicationSource? source;
    try {
      source = await MobiPublicationSource.build(
        request.sourcePath,
        isCancelled: isCancelled,
        onProgress: (value) => onProgress(.65 * value),
        onStage: (stage) => timing?.mark(stage),
      );
      final file = File(p.join(request.workDir, 'mobi.index'));
      await file.parent.create(recursive: true);
      final bytes = source.exportIndex();
      await file.writeAsBytes(bytes, flush: true);
      final digest = await sourceFileDigest(file.path);
      timing?.mark('index_save_sha256');
      final counts = {
        'entries': source.sizes.length,
        'index_bytes': bytes.length,
        'index_phase_read_bytes': source.native.bytesRead,
        'index_phase_decoded_records': source.native.recordsDecoded,
        'retained_record_bytes': source.native.retainedRecordBytes,
        'input_window_fills': source.native.inputWindowFills,
        'input_window_bytes': source.native.inputWindowBytes,
      };
      if (isCancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
      final document = await const EpubParser().parse(
        request,
        entryArchive: EpubArchive.entries(source),
        mobiIndex: {'bytes': bytes.length, 'sha256': digest},
        onProgress: (value) => onProgress(.7 + .3 * (value ?? 0)),
        isCancelled: isCancelled,
        onCover: onCover,
      );
      timing?.mark('epub_index');
      timing?.report(counts: counts);
      return document;
    } on MobiReadFailure catch (error) {
      if (error.status == 6) {
        return parseLegacy(
          request,
          onProgress: onProgress,
          isCancelled: isCancelled,
          onCover: onCover,
        );
      }
      throw switch (error.status) {
        2 => const ImportFailure(
          ImportErrorCode.unsupportedFormat,
          '不支持加密的 MOBI／AZW3',
        ),
        3 => const ImportFailure(
          ImportErrorCode.unsupportedFormat,
          '不支持 Print Replica 版式',
        ),
        4 => const ImportFailure(ImportErrorCode.unsafeArchive, '正文或资源超过大小限制'),
        5 => const ImportFailure(ImportErrorCode.noSpace, '无法读取原书或保存索引'),
        7 => const ImportFailure(ImportErrorCode.cancelled),
        _ => const ImportFailure(
          ImportErrorCode.invalidContainer,
          'MOBI／AZW3 解析失败',
        ),
      };
    } finally {
      source?.close();
    }
  }

  Future<BookDocument> parse(
    ParseRequest request, {
    required ParseProgress onProgress,
    required bool Function() isCancelled,
    ParseCover? onCover,
  }) => request.indexedContent
      ? parseDirect(
          request,
          onProgress: onProgress,
          isCancelled: isCancelled,
          onCover: onCover,
        )
      : parseLegacy(
          request,
          onProgress: onProgress,
          isCancelled: isCancelled,
          onCover: onCover,
        );

  Future<BookDocument> parseLegacy(
    ParseRequest request, {
    required ParseProgress onProgress,
    required bool Function() isCancelled,
    ParseCover? onCover,
  }) async {
    final timing = traceImportPerf ? ImportTiming('mobi_parser') : null;
    var shownPercent = -1;
    void progress(double fraction) {
      final percent = (fraction * 100).floor();
      if (percent == shownPercent) return;
      shownPercent = percent;
      onProgress(fraction);
    }

    final publication = Directory(p.join(request.workDir, 'publication'));
    publication.createSync(recursive: true);
    progress(0);
    final result = extractMobi(request.sourcePath, publication.path);
    timing?.mark('native_extract');
    if (result.status != 0) {
      throw switch (result.status) {
        2 => const ImportFailure(
          ImportErrorCode.unsupportedFormat,
          '不支持加密的 MOBI／AZW3',
        ),
        3 => const ImportFailure(
          ImportErrorCode.unsupportedFormat,
          '不支持 Print Replica 版式',
        ),
        4 => const ImportFailure(ImportErrorCode.unsafeArchive, '正文或资源超过大小限制'),
        5 => const ImportFailure(ImportErrorCode.noSpace, '无法读取原书或写入重建内容'),
        _ => const ImportFailure(
          ImportErrorCode.invalidContainer,
          'MOBI／AZW3 解析失败',
        ),
      };
    }
    if (isCancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
    progress(.15);
    await prepareMobiPublication(
      publication,
      kf8: result.version >= 8,
      onProgress: (fraction) => progress(.15 + .6 * fraction),
    );
    timing?.mark('publication_prepare');
    final container = File(
      p.join(publication.path, 'META-INF', 'container.xml'),
    );
    container.parent.createSync(recursive: true);
    container.writeAsStringSync('''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
    File(p.join(publication.path, 'mimetype'))
        .writeAsStringSync('application/epub+zip');
    final digests = <String, String>{};
    final files = publication
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      digests[p
          .relative(file.path, from: publication.path)
          .replaceAll('\\', '/')] = await sourceFileDigest(
        file.path,
      );
      progress(.75 + .1 * (index + 1) / files.length);
    }
    timing?.mark('publication_sha256');
    final document = await const EpubParser().parse(
      request,
      publicationDirectory: publication.path,
      publicationDigests: digests,
      // 各阶段按实际完成工作推进，不能在开始正文统计时又退回20%。
      onProgress: (fraction) => progress(.85 + .15 * (fraction ?? 0)),
      isCancelled: isCancelled,
      onCover: onCover,
    );
    timing?.mark('epub_index');
    timing?.report(counts: {'files': digests.length});
    return document;
  }
}
