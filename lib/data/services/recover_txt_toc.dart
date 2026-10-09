import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'book_source_path.dart';

import '../../domain/models/book_document.dart';
import '../../domain/services/text_preparation.dart';
import '../../engine/parsers/txt/txt_chapter_rule.dart';

/// 只补旧解析遗漏的省略号章题，不改正文文件、章节 ID 或任何阅读位置。
/// 源文件保留缩进，可排除正文中提到“第…章”的句子。
Future<List<TocNode>> recoverTxtToc({
  required String bookDirectory,
  required List<Chapter> chapters,
  required List<TocNode> nodes,
  required String encoding,
  TextPreparationService? preparation,
}) async {
  const rule = TxtChapterRule();
  if (chapters.where((c) => rule.matchLine(c.title, 0) != null).length < 2) {
    return nodes; // 无目录或用户强制分节的书，不擅自改变其目录。
  }
  final source = File(bookSourcePath(bookDirectory, 'txt'));
  if (!await source.exists()) return nodes;
  Directory? temporary;
  try {
    var path = source.path;
    if (preparation != null) {
      temporary = await Directory.systemTemp.createTemp('gt-txt-toc-');
      path = p.join(temporary.path, 'source.txt');
      final handle = await source.open();
      final header = await handle.read(65536);
      await handle.close();
      await preparation.prepareToUtf8(
        sourcePath: source.path,
        targetPath: path,
        header: header,
        overrideCharset: encoding.isEmpty ? null : encoding,
      );
    }
    return await _recoverInBackground(path, bookDirectory, chapters, nodes);
  } finally {
    await temporary?.delete(recursive: true);
  }
}

Future<List<TocNode>> _recoverInBackground(
  String source,
  String directory,
  List<Chapter> chapters,
  List<TocNode> nodes,
) => Isolate.run(() => _recover(source, directory, chapters, nodes));

Future<List<TocNode>> _recover(
  String source,
  String directory,
  List<Chapter> chapters,
  List<TocNode> nodes,
) async {
  const rule = TxtChapterRule();
  final known = {for (final c in chapters) c.title};
  final missing = <String>{};
  await for (final line in File(
    source,
  ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
    final heading = rule.matchLine(line, 0);
    if (heading?.kind == TxtHeadingKind.chapter &&
        heading!.title.contains('…') &&
        !known.contains(heading.title)) {
      missing.add(heading.title);
    }
  }
  if (missing.isEmpty) return nodes;
  final extras = <String, List<TocNode>>{};
  for (final chapter in chapters) {
    final json = jsonDecode(
      await File(p.join(directory, chapter.contentPath)).readAsString(),
    ) as Map<String, dynamic>;
    final content = ChapterContent.fromJson(json);
    for (final block in content.blocks) {
      final title = block.runs.map((run) => run.text).join().trim();
      if (!missing.contains(title)) continue;
      (extras[chapter.id] ??= []).add(
        TocNode(
          title: title,
          chapterId: chapter.id,
          fragment: 'gt-txt:${block.id}',
        ),
      );
    }
  }
  // 保留原分卷和条目顺序，将章内补充条目紧跟在原章条目后。
  List<TocNode> insert(List<TocNode> entries) => [
    for (final node in entries) ...[
      TocNode(
        title: node.title,
        chapterId: node.chapterId,
        fragment: node.fragment,
        children: insert(node.children),
      ),
      if (node.chapterId case final id?) ...?extras.remove(id),
    ],
  ];
  return insert(
    nodes.isEmpty
        ? [for (final c in chapters) TocNode(title: c.title, chapterId: c.id)]
        : nodes,
  );
}
