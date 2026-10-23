import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/io/source_fingerprint.dart';
import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/import_job.dart';
import '../../domain/models/source_content_index.dart';
import '../../domain/services/book_parser.dart';
import '../../engine/parsers/parse_worker.dart';
import 'book_source_path.dart';

/// 给已有EPUB补齐小型目录位置表。只在书籍读写已交接后调用；不改正文、
/// 目录、数据库或位置。新导入已经带表，不会再次全书解析。
Future<void> prepareEpubTocMetadata({
  required String bookDirectory,
  required String contentDirectory,
  required String workRoot,
  required String displayName,
  required List<Chapter> chapters,
  required Map<String, dynamic> manifest,
  required CancelToken cancel,
}) async {
  final raw = manifest['sourceIndex'] as Map<String, dynamic>;
  final index = SourceContentIndex.fromJson(raw);
  if (index.format != 'epub') return;
  final groups = <String, List<String>>{};
  void collect(List<dynamic> nodes) {
    for (final node in nodes.cast<Map>()) {
      if (node['chapterId'] case final String id) {
        groups.putIfAbsent(id, () => []).add(node['fragment'] as String? ?? '');
      }
      collect(node['children'] as List? ?? const []);
    }
  }

  collect(manifest['toc'] as List);
  final missing = groups.entries.any(
    (entry) =>
        entry.value.length > 1 &&
        (!index.tocHeadings.containsKey(entry.key) ||
            !entry.value.every(
              (fragment) =>
                  fragment.isEmpty ||
                  index.tocPositions[entry.key]?.containsKey(fragment) == true,
            )),
  );
  if (!missing || cancel.isCancelled()) return;

  final source = File(bookSourcePath(bookDirectory, 'epub'));
  final before = sourceFingerprint(await source.stat());
  final file = File(p.join(contentDirectory, 'manifest.json'));
  final attempted = File(p.join(contentDirectory, '.toc-metadata-attempt'));
  Future<String> signature() async =>
      '${index.sourceDigest}:$before:${(await file.stat()).modified.microsecondsSinceEpoch}:1';
  if (await attempted.exists() &&
      await attempted.readAsString() == await signature()) {
    return;
  }
  final parent = await Directory(workRoot).create(recursive: true);
  final temporary = await parent.createTemp('epub-toc-');
  try {
    final document = await const ParseWorker().run(
      request: ParseRequest(
        format: BookFormat.epub,
        sourcePath: source.path,
        displayName: displayName,
        workDir: temporary.path,
        contentVersion: kContentVersion,
        indexedContent: true,
      ),
      onProgress: (_) {},
      cancel: cancel,
    );
    final fresh = document.sourceIndex!;
    final updated = document.toManifestJson();
    // 新目录与旧目录、章节身份及精确统计相同，才能补表。无法确认时留旧表，
    // 正常阅读仍用原来的按需定位，不猜位置或隐式重导入用户书籍。
    if (cancel.isCancelled() ||
        fresh.sourceDigest != index.sourceDigest ||
        fresh.sourceBytes != index.sourceBytes ||
        before != sourceFingerprint(await source.stat()) ||
        jsonEncode(manifest['toc']) != jsonEncode(updated['toc']) ||
        jsonEncode(manifest['chapters']) != jsonEncode(updated['chapters']) ||
        chapters.length != document.chapters.length) {
      return;
    }
    final next = File(p.join(contentDirectory, 'manifest.json.next'));
    await next.writeAsString(
      jsonEncode({
        ...manifest,
        'sourceIndex': {
          ...raw,
          'tocPositions1': fresh.tocPositions,
          'tocHeadings1': fresh.tocHeadings,
        },
      }),
      flush: true,
    );
    if (cancel.isCancelled() ||
        before != sourceFingerprint(await source.stat())) {
      await next.delete();
      return;
    }
    await next.rename(p.join(contentDirectory, 'manifest.json'));
  } finally {
    await temporary.delete(recursive: true);
    // 无法证明兼容的旧目录继续走原定位；不在每次启动重复整书尝试。
    // 用户开书取消的任务不记失败，空闲时仍可继续。
    if (!cancel.isCancelled()) await attempted.writeAsString(await signature());
  }
}

/// 恢复暂存中的目录表也要与原书重新计算的结果一致。备份创建复用已核验
/// 本机数据，不调用此完整扫描；恢复不能只信备份自行填写的摘要和目录比例。
Future<void> validateEpubTocMetadata(
  String source,
  Map<String, dynamic> manifest,
) async {
  final stored = manifest['sourceIndex'] as Map;
  final temporary = await Directory.systemTemp.createTemp('epub-toc-restore-');
  try {
    final document = await const ParseWorker().run(
      request: ParseRequest(
        format: BookFormat.epub,
        sourcePath: source,
        displayName: 'source.epub',
        workDir: temporary.path,
        contentVersion: kContentVersion,
        indexedContent: true,
      ),
      onProgress: (_) {},
      cancel: CancelToken(),
    );
    final index = document.sourceIndex!;
    if ((stored['tocPositions1'] != null &&
            jsonEncode(stored['tocPositions1']) !=
                jsonEncode(index.tocPositions)) ||
        (stored['tocHeadings1'] != null &&
            jsonEncode(stored['tocHeadings1']) !=
                jsonEncode(index.tocHeadings)) ||
        jsonEncode(manifest['chapters']) !=
            jsonEncode(document.toManifestJson()['chapters']) ||
        jsonEncode(manifest['toc']) !=
            jsonEncode(document.toManifestJson()['toc'])) {
      throw const FormatException('EPUB目录位置或章节统计与原书不一致');
    }
  } finally {
    await temporary.delete(recursive: true);
  }
}
