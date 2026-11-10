import 'dart:io';
import 'dart:isolate';

import '../../domain/models/book_document.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_package.dart';
import '../../engine/parsers/epub/xhtml_blocks.dart';

/// 旧的逐章JSON曾漏存显示来源。只在完整正文、图片位置都相同时补显示资料，
/// 原文件及持久正文不重写；不能靠标题默认倍率猜作者是否明确写了1em。
Future<ChapterContent> refreshLegacyPublicationStyles(
  ChapterContent content,
  Chapter chapter,
  String contentDirectory,
  String sourcePath,
) => Isolate.run(() {
  final publication = Directory('$contentDirectory/publication');
  if (!publication.existsSync() && !File(sourcePath).existsSync()) {
    return content;
  }
  EpubArchive? archive;
  try {
    archive = publication.existsSync()
        ? EpubArchive.directory(publication.path)
        : EpubArchive.open(sourcePath);
    final package = EpubPackage.parse(
      archive,
      EpubPackage.readOpfPath(archive),
    );
    final item = package.spine.where((i) => i.href == chapter.href).firstOrNull;
    if (item == null) return content;
    final book = archive;
    final parsed = XhtmlBlockBuilder(
      basePath: item.entryPath,
      buildTextMap: false,
      styleTextResolver: (path) =>
          book.contains(path) ? book.readText(path) : null,
      resolveImage: (path) => book.contains(path)
          ? ResolvedImage(resourcePath: 'res/$path', width: -1, height: -1)
          : null,
    ).convertBytes(book.readBytes(item.entryPath));
    if (parsed.blocks.length != content.blocks.length) return content;
    for (var i = 0; i < parsed.blocks.length; i++) {
      final old = content.blocks[i], next = parsed.blocks[i];
      if (old.id != next.id ||
          old.kind != next.kind ||
          old.runs.map((r) => r.text).join() !=
              next.runs.map((r) => r.text).join() ||
          old.textLength != next.textLength ||
          old.resourcePath != next.resourcePath ||
          old.inlineImages.length != next.inlineImages.length) {
        return content;
      }
      for (var j = 0; j < old.inlineImages.length; j++) {
        if (old.inlineImages[j].offset != next.inlineImages[j].offset ||
            old.inlineImages[j].resourcePath !=
                next.inlineImages[j].resourcePath) {
          return content;
        }
      }
    }
    return ChapterContent(
      chapterId: content.chapterId,
      blocks: [
        for (var i = 0; i < parsed.blocks.length; i++)
          ContentBlock.fromJson({
            ...parsed.blocks[i].toJson(),
            // 已提取的原图尺寸不能被重新转换用的占位尺寸覆盖。
            if (content.blocks[i].resourceWidth != null)
              'width': content.blocks[i].resourceWidth,
            if (content.blocks[i].resourceHeight != null)
              'height': content.blocks[i].resourceHeight,
            if (parsed.blocks[i].inlineImages.isNotEmpty)
              'iim': [
                for (var j = 0; j < parsed.blocks[i].inlineImages.length; j++)
                  {
                    ...parsed.blocks[i].inlineImages[j].toJson(),
                    'w': content.blocks[i].inlineImages[j].width,
                    'h': content.blocks[i].inlineImages[j].height,
                  },
              ],
          }),
      ],
      tables: parsed.tables,
      epubDetailsRevision: kEpubDetailsRevision,
      stylesJson: parsed.stylesJson,
      displaySourceJson: parsed.displaySourceJson,
    );
  } on Object {
    // 源书缺失、已变化或新旧正文不符时沿用已保存资料，不改业务数据。
    return content;
  } finally {
    archive?.close();
  }
});
