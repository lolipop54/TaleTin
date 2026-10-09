import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';
import '../../domain/models/content_table.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_package.dart';
import '../../engine/parsers/epub/image_sniff.dart';
import '../../engine/parsers/epub/xhtml_blocks.dart';

/// 旧书补充显示资料，不重写正文文件、块号或文本，笔记和听书坐标保持不变。
ChapterContent enrichEpubContent(
  ChapterContent content,
  Chapter chapter,
  String contentDirectory,
  String sourcePath,
) {
  final blocks = content.blocks.map((block) {
    final resource = block.resourcePath;
    if (block.kind != BlockKind.image ||
        resource == null ||
        !resource.toLowerCase().endsWith('.svg') ||
        (block.resourceWidth != 1 && block.resourceHeight != 1)) {
      return block;
    }
    final file = File(p.join(contentDirectory, resource));
    if (!file.existsSync()) return block;
    final size = sniffSvgSize(file.readAsBytesSync());
    if (size == null) return block;
    return ContentBlock.fromJson({
      ...block.toJson(),
      'width': size.width,
      'height': size.height,
    });
  }).toList();
  var tables = content.tables;
  if (tables.isEmpty && chapter.href != null && File(sourcePath).existsSync()) {
    final archive = EpubArchive.open(sourcePath);
    try {
      final package = EpubPackage.parse(
        archive,
        EpubPackage.readOpfPath(archive),
      );
      final item = package.spine
          .where((i) => i.href == chapter.href)
          .firstOrNull;
      if (item != null) {
        final html = archive.readText(item.entryPath);
        if (html.contains('<table')) {
          final parsed = XhtmlBlockBuilder(
            basePath: item.entryPath,
            resolveImage: (path) => archive.contains(path)
                ? ResolvedImage(resourcePath: 'res/$path', width: 1, height: 1)
                : null,
          ).convert(html);
          // 只应用完全匹配的结构；旧格式内容有差异时不猜测位置。
          if (parsed.blocks.length == blocks.length &&
              parsed.blocks.indexed.every(
                (entry) =>
                    entry.$2.kind == blocks[entry.$1].kind &&
                    entry.$2.runs.map((r) => r.text).join() ==
                        blocks[entry.$1].runs.map((r) => r.text).join(),
              )) {
            final ids = {
              for (var i = 0; i < blocks.length; i++)
                parsed.blocks[i].id: blocks[i].id,
            };
            tables = [
              for (final table in parsed.tables)
                ContentTable(
                  [
                    for (final cell in table.cells)
                      ContentTableCell(
                        blocks: cell.blocks.map((id) => ids[id]!).toList(),
                        row: cell.row,
                        column: cell.column,
                        rowSpan: cell.rowSpan,
                        columnSpan: cell.columnSpan,
                        header: cell.header,
                      ),
                  ],
                  table.columns,
                  table.rows,
                ),
            ];
          }
        }
      }
    } finally {
      archive.close();
    }
  }
  return ChapterContent(
    chapterId: content.chapterId,
    blocks: blocks,
    tables: tables,
  );
}
