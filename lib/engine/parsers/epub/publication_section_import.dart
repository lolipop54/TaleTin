import 'dart:io';

import '../../../core/errors/import_error.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/services/toc_entry_index.dart';
import '../../normalization/text_decoding.dart';
import 'epub_archive.dart';
import 'publication_section_slices.dart';
import 'publication_section_store.dart';
import 'publication_spread_chapters.dart';
import 'publication_style_tree.dart';
import '../../styles/chapter_styler.dart';
import 'xhtml_blocks.dart';

/// 在导入的暂存目录生成选择性缓存。原 ZIP 和导入时确定的章、块编号保持原样。
void preparePublicationReadingSections(
  EpubArchive archive,
  String directory,
  String digest,
  List<Chapter> chapters,
  Map<String, List<Object>> sources,
  List<String>? cover,
  List<TocNode> toc,
  Map<String, Map<String, double?>> positions,
  Set<String> availableImages,
  String? Function(String) css,
  ImageResolver images,
  bool Function() cancelled,
) {
  final titles = collectTocTitles(toc);
  final styleBook =
      cover != null &&
      publicationCssMode != 'legacy' &&
      PublicationStyleTree.bind(directory, digest);
  for (final chapter in chapters) {
    if (cancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
    final path = sources[chapter.id]!.single as String;
    if (chapter.textLength < publicationSectionMinText &&
        archive.find(path)!.size < publicationSectionMinHtml) {
      continue;
    }
    archive.resetTotalBudget();
    final raw = archive.readBytes(path);
    final parsed = XhtmlBlockBuilder(
      legacyMobi: archive.legacyMobi,
      basePath: path,
      buildTextMap: false,
      containsResource: archive.contains,
      styleTextResolver: css,
      styleBook: styleBook ? digest : null,
      resolveImage: images,
    ).convertBytes(raw);
    if (parsed.textLength != chapter.textLength) continue;
    final body = withPublicationSpreadChapters(
      ChapterContent(
        chapterId: chapter.id,
        blocks: parsed.blocks,
        tables: parsed.tables,
        epubDetailsRevision: kEpubDetailsRevision,
        stylesJson: parsed.stylesJson,
        displaySourceJson: cover == null
            ? parsed.displaySourceJson
            : parsed.displayWithCover(
                cover,
                path,
                first: chapter.ordinal == 0,
                title: chapter.title,
              ),
      ),
      titles[chapter.id] ?? const [],
      positions: positions[path],
      continuation: cover == null && isKindleContinuation(path),
    );
    final cuts = publicationSectionBoundaries(body);
    try {
      PublicationSectionStore(directory, chapter.id, digest).write(
        ChapterStyler.toStylesOnly(ChapterStyler.apply(body)),
        cuts,
        cuts.isEmpty
            ? const {}
            : publicationSectionAnchors(
                decodeTextBytes(raw),
                chapter,
                path,
                images: availableImages,
                legacyMobi: archive.legacyMobi,
              ),
      );
    } on FileSystemException {
      // 这份数据可在读章时重建。写入失败时仍可用原 ZIP 阅读。
    }
  }
}
