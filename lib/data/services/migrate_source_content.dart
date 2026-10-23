import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/import_job.dart';
import '../../domain/services/book_parser.dart';
import '../../domain/services/text_preparation.dart';
import '../../domain/services/library_file_gate.dart';
import '../../domain/repositories/book_repository.dart';
import '../repositories/file_chapter_content_repository.dart';
import '../../engine/parsers/parse_worker.dart';
import 'book_source_path.dart';
import 'indexed_chapter_reader.dart';
import 'migrate_mobi_storage.dart';
import 'prepare_epub_toc_metadata.dart';

/// 首次升级时核对旧章；清单原子切换成功后，JSON 才成为可删除的重复数据。
/// 只改来源索引，数据库、目录、阅读位置和笔记全部保留。
class SourceContentMigration {
  SourceContentMigration({
    required this.libraryRoot,
    required this.workRoot,
    required this.preparation,
    this.activeBooks,
  });
  final String libraryRoot, workRoot;
  final TextPreparationService preparation;
  final Set<String> Function()? activeBooks;
  CancelToken? _migrationCancel;
  bool _stopped = false;
  Future<Object?>? _active;

  /// 每次只锁正在核对的书。备份等待本书结束，其他书和界面可以正常使用。
  Future<int> runLibrary(
    BookRepository books,
    FileChapterContentRepository contents,
    LibraryFileGate gate,
  ) async {
    var released = 0;
    final listing = books.watchActiveBooks().first;
    _active = listing;
    final library = await listing;
    for (final book in library) {
      if (_stopped) break;
      if (contents.usedBookIds.contains(book.id) ||
          activeBooks?.call().contains(book.id) == true) {
        continue;
      }
      final release = await gate.enter();
      final releaseBook = await gate.enterBook(book.id);
      if (_stopped) {
        release();
        releaseBook();
        break;
      }
      try {
        final work = () async {
          final token = _migrationCancel = CancelToken();
          final current = await books.findById(book.id);
          if (current == null || current.status != BookStatus.active) return 0;
          final chapters = await books.chaptersOf(book.id);
          return contents.migrateContent(
            book.id,
            book.contentVersion,
            () => migrate(current, chapters),
            onReadRequested: token.cancelAll,
          );
        }();
        _active = work;
        released += await work;
      } on Object {
        // 某一本旧书清单损坏或文件不可读，保留它的原数据并继续核对其他书。
      } finally {
        _migrationCancel = null;
        releaseBook();
        release();
      }
    }
    return released;
  }

  /// 恢复可能已经冻结文件操作；只等已进入的迁移，不等尚未拿到文件权限的下一本。
  Future<void> stop() async {
    _stopped = true;
    _migrationCancel?.cancelAll();
    try {
      await _active;
    } on Object {
      /* 原数据保留，继续关闭其他服务。 */
    }
  }

  Future<int> migrate(Book book, List<Chapter> chapters) async {
    // PDF的JSON保存文字与原页坐标，是持久阅读资料，不能当成旧版重复正文清理。
    if (book.format == BookFormat.pdf) return 0;
    if (book.contentVersion != kContentVersion || chapters.isEmpty) return 0;
    final directory = p.join(libraryRoot, book.id);
    final content = p.join(directory, 'content', '${book.contentVersion}');
    final file = File(p.join(content, 'manifest.json'));
    final source = File(bookSourcePath(directory, book.format.code));
    if (!await file.exists() || !await source.exists()) return 0;
    final manifest =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (book.format == BookFormat.mobi || book.format == BookFormat.azw3) {
      return MobiStorageMigration(
        libraryRoot,
        workRoot,
      ).migrate(book, chapters, _migrationCancel ?? CancelToken());
    }
    if (manifest['sourceIndex'] != null) {
      if (book.format == BookFormat.epub) {
        await prepareEpubTocMetadata(
          bookDirectory: directory,
          contentDirectory: content,
          workRoot: workRoot,
          displayName: book.title,
          chapters: chapters,
          manifest: manifest,
          cancel: _migrationCancel ?? CancelToken(),
        );
      }
      // 上次在提交索引之后被系统终止：继续清理即可，无须再次生成整本。
      return await Isolate.run(() => _removeChapters(directory, chapters));
    }
    final stat = await source.stat();
    final signature =
        '${stat.size}:${stat.modified.microsecondsSinceEpoch}:'
        '${(await file.stat()).modified.microsecondsSinceEpoch}:1';
    final attempted = File(p.join(content, '.source-migration'));
    if (await attempted.exists() &&
        await attempted.readAsString() == signature) {
      return 0;
    }
    final root = Directory(workRoot);
    await root.create(recursive: true);
    final temporary = await root.createTemp('source-migration-');
    try {
      String? textPath, charset;
      if (book.format == BookFormat.txt) {
        final handle = await source.open();
        final Uint8List header;
        try {
          header = await handle.read(8192);
        } finally {
          await handle.close();
        }
        charset = manifest['encoding'] as String?;
        if (charset == null || charset.isEmpty) {
          charset = preparation.detectEncoding(header).charset;
        }
        textPath = source.path;
        if (charset != 'UTF-8') {
          textPath = p.join(temporary.path, 'text.txt');
          await preparation.prepareToUtf8(
            sourcePath: source.path,
            targetPath: textPath,
            header: header,
            overrideCharset: charset,
          );
        }
      }
      final document = await const ParseWorker().run(
        request: ParseRequest(
          format: book.format,
          sourcePath: source.path,
          displayName: book.title,
          workDir: temporary.path,
          contentVersion: book.contentVersion,
          textPath: textPath,
          txt: charset == null ? null : TxtOptions(charset: charset),
          indexedContent: true,
        ),
        onProgress: (_) {},
        cancel: CancelToken(),
      );
      if (!_sameChapters(chapters, document.chapters)) {
        await attempted.writeAsString(signature);
        return 0;
      }
      // GB 系编码通过平台转成一次性 UTF-8，后台比对时按原字节区间解码。
      // 逐章请求平台会跨 isolate；验证改为复用后台工作器的消息通道。
      final valid = await _verify(directory, temporary.path, content, chapters);
      if (!valid) {
        await attempted.writeAsString(signature);
        return 0;
      }
      final next = File('${file.path}.next');
      await next.writeAsString(
        jsonEncode({
          ...manifest,
          'sourceIndex': document.sourceIndex!.toJson(),
        }),
        flush: true,
      );
      await next.rename(file.path);
      if (await attempted.exists()) await attempted.delete();
      return await Isolate.run(() => _removeChapters(directory, chapters));
    } on Object {
      // 源书失效、旧章缺失或无法确认一致时保留原正文，不自动猜测或覆盖。
      return 0;
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }

  Future<bool> _verify(
    String directory,
    String candidate,
    String content,
    List<Chapter> chapters,
  ) async {
    final messages = ReceivePort();
    final worker = await Isolate.spawn(
      _verifyWorker,
      (messages.sendPort, directory, candidate, content, chapters),
      onError: messages.sendPort,
      onExit: messages.sendPort,
    );
    try {
      await for (final message in messages) {
        if (message is bool) return message;
        if (message case (SendPort reply, Uint8List bytes, String charset)) {
          try {
            reply.send(
              await preparation.preview(bytes: bytes, charset: charset),
            );
          } catch (_) {
            reply.send(null);
          }
        } else {
          return false;
        }
      }
      return false;
    } finally {
      messages.close();
      worker.kill(priority: Isolate.immediate);
    }
  }
}

bool _sameChapters(List<Chapter> old, List<Chapter> next) {
  if (old.length != next.length) return false;
  for (var i = 0; i < old.length; i++) {
    final a = old[i], b = next[i];
    if (a.id != b.id ||
        a.ordinal != b.ordinal ||
        a.contentPath != b.contentPath ||
        a.textLength != b.textLength ||
        a.href != b.href) {
      return false;
    }
  }
  return true;
}

Future<void> _verifyWorker(
  (SendPort, String, String, String, List<Chapter>) args,
) async {
  final (reply, directory, candidate, content, chapters) = args;
  IndexedChapterReader? reader;
  try {
    reader = IndexedChapterReader.open(directory, candidate);
    await reader.verifySource();
    for (final chapter in chapters) {
      final generated = await reader.read(chapter, (bytes, charset) async {
        final response = ReceivePort();
        try {
          reply.send((response.sendPort, bytes, charset));
          final text = await response.first;
          if (text is! String) throw const FormatException('无法核对编码');
          return text;
        } finally {
          response.close();
        }
      });
      final old = ChapterContent.fromJson(
        (jsonDecode(
          File(p.join(directory, chapter.contentPath)).readAsStringSync(),
        ) as Map).cast<String, Object?>(),
      );
      // 规则完成标记不是正文；其余字段（包括样式、表格、图片和脚注）逐项相同。
      Map<String, Object?> body(ChapterContent c) =>
          {...c.toJson()}..remove('epubDetailsRevision');
      if (jsonEncode(body(old)) != jsonEncode(body(generated))) {
        reply.send(false);
        return;
      }
    }
    for (final path in reader.index.images.keys) {
      var a = File(p.join(candidate, 'res', path));
      if (!a.existsSync() && reader.cache != null) {
        a = reader.cache!.file(p.join('assets', path));
      }
      final b = File(p.join(content, 'res', path));
      if (!b.existsSync() ||
          sha256.convert(a.readAsBytesSync()) !=
              sha256.convert(b.readAsBytesSync())) {
        reply.send(false);
        return;
      }
    }
    // 全书核对可能持续数秒，再确认外部源文件没有在核对期间被改写。
    await reader.verifySource();
    reply.send(true);
  } catch (_) {
    reply.send(false);
  } finally {
    await reader?.close();
  }
}

int _removeChapters(String directory, List<Chapter> chapters) {
  var released = 0;
  for (final chapter in chapters) {
    final file = File(p.join(directory, chapter.contentPath));
    if (!p.isWithin(directory, file.path) || !file.existsSync()) continue;
    released += file.lengthSync();
    file.deleteSync();
  }
  return released;
}
