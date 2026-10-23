import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:direct_read_rust/direct_read_rust.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/import_job.dart';
import '../../domain/models/source_content_index.dart';
import '../../domain/services/book_parser.dart';
import '../../engine/parsers/parse_worker.dart';
import '../../engine/parsers/mobi/mobi_source.dart';
import '../../engine/parsers/epub/image_sniff.dart';
import 'book_source_path.dart';
import 'indexed_chapter_reader.dart';

/// A storage-only transaction. The database, locators, notes and their dates
/// never change; the old publication remains intact until verification passes.
class MobiStorageMigration {
  const MobiStorageMigration(this.libraryRoot, this.workRoot);
  final String libraryRoot, workRoot;

  Future<int> migrate(
    Book book,
    List<Chapter> chapters,
    CancelToken cancel,
  ) async {
    final bookDirectory = p.join(libraryRoot, book.id);
    final content = p.join(bookDirectory, 'content', '${book.contentVersion}');
    final manifestFile = File(p.join(content, 'manifest.json'));
    final journal = File(p.join(content, '.mobi-migration.json'));
    final indexFile = File(p.join(content, 'mobi.index'));
    if (!await manifestFile.exists()) return 0;
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final rawIndex = manifest['sourceIndex'] as Map<String, dynamic>?;
    if (rawIndex != null && SourceContentIndex.fromJson(rawIndex).directMobi) {
      // After an interrupted cleanup, the committed index is already readable.
      if (!await journal.exists()) return 0;
      final reader = IndexedChapterReader.open(bookDirectory, content);
      try {
        await reader.verifySource();
        for (final at in {0, chapters.length ~/ 2, chapters.length - 1}) {
          await reader.read(
            chapters[at],
            (_, _) async => throw StateError('非TXT'),
            textOnly: true,
          );
        }
      } finally {
        reader.close();
      }
      final freed = await _removeExpanded(content, manifest, chapters);
      await journal.delete();
      return freed;
    }
    if (await journal.exists()) {
      // Index publication happened before the atomic manifest switch.
      if (await indexFile.exists()) await indexFile.delete();
      await journal.delete();
    }
    // 已取消的任务只完成上面的未提交日志回滚，不再打开新的解码会话。
    if (cancel.isCancelled()) return 0;
    final source = File(bookSourcePath(bookDirectory, book.format.code));
    if (!await source.exists()) return 0;
    final stat = await source.stat();
    final attempt = File(p.join(content, '.mobi-migration-attempt'));
    final signature =
        '${stat.size}:${stat.modified.microsecondsSinceEpoch}:'
        '${stat.changed.microsecondsSinceEpoch}:${rawIndex?['sourceDigest']}:recipes2';
    if (await attempt.exists() && await attempt.readAsString() == signature) {
      return 0;
    }
    final temporary = await (Directory(
      workRoot,
    )..createSync(recursive: true)).createTemp('mobi-migration-');
    var committed = false, cleaning = false;
    try {
      final document = await const ParseWorker().run(
        request: ParseRequest(
          format: book.format,
          sourcePath: source.path,
          displayName: book.sourceFileName ?? p.basename(source.path),
          workDir: temporary.path,
          contentVersion: book.contentVersion,
          indexedContent: true,
        ),
        onProgress: (_) {},
        cancel: cancel,
      );
      if (document.sourceIndex?.directMobi != true ||
          jsonEncode(manifest['chapters']) !=
              jsonEncode(document.toManifestJson()['chapters']) ||
          jsonEncode(manifest['toc']) !=
              jsonEncode(document.toManifestJson()['toc'])) {
        if (!cancel.isCancelled()) await attempt.writeAsString(signature);
        return 0;
      }
      await File(p.join(temporary.path, 'manifest.json'))
          .writeAsString(jsonEncode(document.toManifestJson()), flush: true);
      final verified = await _verifyCancellable(
        bookDirectory,
        content,
        temporary.path,
        chapters,
        cancel,
      );
      if (!verified || cancel.isCancelled()) {
        if (!cancel.isCancelled()) await attempt.writeAsString(signature);
        return 0;
      }
      // The already-present persistent cover must be byte-for-byte preserved.
      final cover = manifest['cover'] as String?;
      if (cover != null) {
        final oldCover = File(p.join(content, cover));
        final newCover = File(p.join(temporary.path, cover));
        if (!await oldCover.exists() ||
            !await newCover.exists() ||
            await nativeFileDigest(oldCover.path) !=
                await nativeFileDigest(newCover.path)) {
          return 0;
        }
      }
      final oldBytes = await manifestFile.readAsBytes();
      await journal.writeAsString(
        jsonEncode({'version': 1, 'index': document.sourceIndex!.mobiIndex}),
        flush: true,
      );
      await File(p.join(temporary.path, 'mobi.index'))
          .copy('${indexFile.path}.next');
      final indexHandle = await File('${indexFile.path}.next')
          .open(mode: FileMode.append);
      try {
        await indexHandle.flush();
      } finally {
        await indexHandle.close();
      }
      await File('${indexFile.path}.next').rename(indexFile.path);
      if (cancel.isCancelled()) return 0;
      final next = File('${manifestFile.path}.next');
      await next.writeAsString(
        jsonEncode({
          ...manifest,
          'sourceIndex': document.sourceIndex!.toJson(),
        }),
        flush: true,
      );
      if (cancel.isCancelled()) return 0;
      await next.rename(manifestFile.path);
      committed = true;
      // Reopen the published location before reclaiming any previous body.
      final reader = IndexedChapterReader.open(bookDirectory, content);
      try {
        await reader.verifySource();
        for (final at in {0, chapters.length ~/ 2, chapters.length - 1}) {
          await reader.read(
            chapters[at],
            (_, _) async => throw StateError('非TXT'),
            textOnly: true,
          );
        }
      } catch (_) {
        await File('${manifestFile.path}.next')
            .writeAsBytes(oldBytes, flush: true);
        await File('${manifestFile.path}.next').rename(manifestFile.path);
        committed = false;
        rethrow;
      } finally {
        reader.close();
      }
      cleaning = true;
      final freed = await _removeExpanded(content, {
        ...manifest,
        'sourceIndex': document.sourceIndex!.toJson(),
      }, chapters);
      if (await attempt.exists()) await attempt.delete();
      await journal.delete();
      return freed - (document.sourceIndex!.mobiIndex['bytes'] as int);
    } catch (_) {
      // A committed, verified index remains the complete source if cleanup was
      // interrupted. The journal makes the remaining cleanup restartable.
      if (cleaning) return 0;
      if (!cancel.isCancelled()) await attempt.writeAsString(signature);
      return 0;
    } finally {
      if (!committed) {
        if (await indexFile.exists()) await indexFile.delete();
        if (await journal.exists()) await journal.delete();
        final unfinished = File('${indexFile.path}.next');
        if (await unfinished.exists()) await unfinished.delete();
        final unfinishedManifest = File('${manifestFile.path}.next');
        if (await unfinishedManifest.exists()) {
          await unfinishedManifest.delete();
        }
      }
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }
}

Future<bool> _verifyCancellable(
  String book,
  String content,
  String candidate,
  List<Chapter> chapters,
  CancelToken cancel,
) async {
  final port = ReceivePort();
  final done = Completer<bool>(), exited = Completer<void>();
  final isolate = await Isolate.spawn(
    _verifyWorker,
    (port.sendPort, book, content, candidate, chapters),
    onExit: port.sendPort,
    onError: port.sendPort,
  );
  port.listen((message) {
    if (message == null) {
      if (!done.isCompleted) done.complete(false);
      if (!exited.isCompleted) exited.complete();
    } else if (!done.isCompleted) {
      done.complete(message is bool && message);
    }
  });
  final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
    if (cancel.isCancelled()) isolate.kill(priority: Isolate.immediate);
  });
  try {
    final result = await done.future;
    await exited.future;
    return result && !cancel.isCancelled();
  } finally {
    timer.cancel();
    port.close();
  }
}

Future<void> _verifyWorker(
  (SendPort, String, String, String, List<Chapter>) input,
) async {
  final (reply, book, oldPath, candidate, chapters) = input;
  IndexedChapterReader? oldReader, newReader;
  MobiPublicationSource? publication;
  try {
    final old = jsonDecode(
      File(p.join(oldPath, 'manifest.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    final next = jsonDecode(
      File(p.join(candidate, 'manifest.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    final index = SourceContentIndex.fromJson(
      next['sourceIndex'] as Map<String, dynamic>,
    );
    final source = bookSourcePath(book, index.format);
    publication = MobiPublicationSource.open(
      source,
      File(p.join(candidate, 'mobi.index')),
      digest: index.mobiIndex['sha256'] as String,
      bytes: index.mobiIndex['bytes'] as int,
    );
    final Map<String, String> previousEntries;
    if (old['sourceIndex'] != null) {
      oldReader = IndexedChapterReader.open(book, oldPath);
      await oldReader.verifySource();
      if (oldReader.index.sourceDigest != index.sourceDigest) {
        reply.send(false);
        return;
      }
      previousEntries = oldReader.index.publication;
    } else {
      // Older MOBI imports have chapter JSON plus the same publication. Verify
      // their actual files, rather than requiring a newer sourceIndex to exist.
      final folder = Directory(p.join(oldPath, 'publication'));
      if (!folder.existsSync()) {
        reply.send(false);
        return;
      }
      previousEntries = {};
      await for (final file in folder.list(
        recursive: true,
        followLinks: false,
      )) {
        if (file is File) {
          previousEntries[p
              .relative(file.path, from: folder.path)
              .replaceAll('\\', '/')] = await nativeFileDigest(
            file.path,
          );
        }
      }
    }
    if (previousEntries.keys
            .toSet()
            .difference(publication.sizes.keys.toSet())
            .isNotEmpty ||
        publication.sizes.keys
            .toSet()
            .difference(previousEntries.keys.toSet())
            .isNotEmpty) {
      reply.send(false);
      return;
    }
    for (final entry in previousEntries.entries) {
      final hash = NativeSha256();
      try {
        hash.add(publication.readBytes(entry.key));
        if (hash.finish() != entry.value ||
            await nativeFileDigest(p.join(oldPath, 'publication', entry.key)) !=
                entry.value) {
          reply.send(false);
          return;
        }
      } finally {
        hash.close();
      }
    }
    newReader = IndexedChapterReader.open(book, candidate);
    await newReader.verifySource();
    for (final chapter in chapters) {
      final previous = oldReader != null
          ? await oldReader.read(
              chapter,
              (_, _) async => throw StateError('非TXT'),
              textOnly: true,
            )
          : ChapterContent.fromJson(
              (jsonDecode(
                File(p.join(book, chapter.contentPath)).readAsStringSync(),
              ) as Map).cast<String, Object?>(),
            );
      // Old chapter JSON already contains image dimensions. Check each against
      // the source and use them only in this in-memory comparison; no resource
      // extraction, cache lease or persistent whole-book images are needed.
      for (final block in previous.blocks) {
        final path = block.resourcePath;
        if (path == null ||
            !path.startsWith('res/') ||
            (block.resourceWidth ?? 0) <= 0 ||
            (block.resourceHeight ?? 0) <= 0) {
          continue;
        }
        final entry = path.substring(4);
        if (newReader.index.images[entry]?[0] == block.resourceWidth &&
            newReader.index.images[entry]?[1] == block.resourceHeight) {
          continue;
        }
        final dimensions = sniffImageSize(publication.readBytes(entry));
        if (dimensions.width != block.resourceWidth ||
            dimensions.height != block.resourceHeight) {
          reply.send(false);
          return;
        }
        newReader.index.images[entry] = [dimensions.width, dimensions.height];
      }
      final generated = await newReader.read(
        chapter,
        (_, _) async => throw StateError('非TXT'),
        textOnly: true,
      );
      Map<String, Object?> body(ChapterContent value) =>
          {...value.toJson()}..remove('epubDetailsRevision');
      if (jsonEncode(body(generated)) != jsonEncode(body(previous))) {
        reply.send(false);
        return;
      }
    }
    await oldReader?.verifySource();
    await newReader.verifySource();
    reply.send(true);
  } catch (_) {
    reply.send(false);
  } finally {
    await oldReader?.close();
    await newReader?.close();
    publication?.close();
  }
}

Future<int> _removeExpanded(
  String content,
  Map<String, dynamic> manifest,
  List<Chapter> chapters,
) async {
  var freed = 0;
  final root = p.normalize(p.absolute(content));
  final publication = Directory(p.join(root, 'publication'));
  if (!p.isWithin(root, publication.path)) {
    throw const FormatException('MOBI旧正文路径越界');
  }
  if (await publication.exists()) {
    await for (final entry in publication.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is Link) throw const FormatException('MOBI旧正文包含链接');
      if (entry is File) freed += await entry.length();
    }
    await publication.delete(recursive: true);
  }
  final keep = manifest['cover'] as String?;
  final images =
      ((manifest['sourceIndex'] as Map?)?['images'] as Map?)?.keys
          .cast<String>() ??
      const <String>[];
  for (final entry in images) {
    final path = p.normalize(p.join(root, 'res', entry));
    if (!p.isWithin(root, path) || p.join(root, keep ?? '') == path) continue;
    final file = File(path);
    if (await file.exists()) {
      freed += await file.length();
      await file.delete();
    }
  }
  for (final chapter in chapters) {
    final file = File(p.join(p.dirname(p.dirname(root)), chapter.contentPath));
    if (!p.isWithin(root, file.path) || !await file.exists()) continue;
    freed += await file.length();
    await file.delete();
  }
  return freed;
}
