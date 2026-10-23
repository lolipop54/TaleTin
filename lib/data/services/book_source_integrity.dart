import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../core/io/source_digest.dart';

import 'package:direct_read_rust/direct_read_rust.dart';

import '../../domain/models/book.dart';
import 'book_source_path.dart';
import 'source_verification_record.dart';

Future<String> _digestFile(String path) {
  final features = ProcessingFeatures.mask;
  return Isolate.run(() {
    ProcessingFeatures.configureExperiment(features);
    return sourceFileDigest(path);
  });
}

Future<(String, int, String?)?> _sourceIndex(String path) => Isolate.run(() {
  final index =
      (jsonDecode(File(path).readAsStringSync()) as Map)['sourceIndex'] as Map?;
  return index == null
      ? null
      : (
          index['sourceDigest'] as String,
          index['sourceBytes'] as int,
          index['sourceStamp'] as String?,
        );
});

String _stamp(FileStat stat) =>
    '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';

/// 书架和开书共用核验结果。轮询只查属性，属性或来源索引变了才后台算摘要。
class BookSourceIntegrity {
  BookSourceIntegrity(this.libraryRoot);
  final String? libraryRoot;
  final _verified = <String, (String, BookStatus)>{};
  final _indexes = <String, (String, (String, int, String?)?)>{};
  final _pending = <String, Future<BookStatus>>{};
  Future<void> _hashing = Future.value();

  Future<void> forget(String bookId) async {
    await Future.wait(
      _pending.entries
          .where((entry) => entry.key.startsWith('$bookId:'))
          .map(
            (entry) => entry.value.then<void>((_) {}, onError: (Object _) {}),
          )
          .toList(),
    );
    _verified.remove(bookId);
    final root = libraryRoot;
    if (root != null) {
      _indexes.removeWhere((path, _) => p.isWithin(p.join(root, bookId), path));
    }
  }

  Future<Book> check(Book book) async {
    if (book.status == BookStatus.removed) return book;
    final root = libraryRoot;
    // 无真实来源索引的旧正文不需要来源属性检查，仍由正文读取判断是否缺失。
    if (book.localSourcePath == null &&
        (root == null ||
            !File(
              p.join(
                root,
                book.id,
                'content',
                '${book.contentVersion}',
                'manifest.json',
              ),
            ).existsSync())) {
      return book;
    }
    final source =
        book.localSourcePath ??
        (root == null
            ? null
            : bookSourcePath(p.join(root, book.id), book.format.code));
    final manifest = root == null
        ? null
        : p.join(
            root,
            book.id,
            'content',
            '${book.contentVersion}',
            'manifest.json',
          );
    // 新索引发布或源文件变化后不合并到旧一轮核验，避免旧结果撤销刚完成的更新。
    final stamp = source == null ? '' : _stamp(await File(source).stat());
    final indexStamp = manifest == null
        ? ''
        : _stamp(await File(manifest).stat());
    final key = '${book.id}:${book.status.code}:$stamp:$indexStamp';
    return book.copyWith(
      status: await _pending.putIfAbsent(
        key,
        () => _check(book).then((checked) => checked.status).whenComplete(() {
          _pending.remove(key);
        }),
      ),
    );
  }

  Future<Book> _check(Book book) async {
    if (book.status == BookStatus.removed) return book;
    final root = libraryRoot;
    // 无外部路径、无真实来源索引的旧书仍由旧 JSON 读取流程判断正文状态。
    if (book.localSourcePath == null &&
        (root == null ||
            !File(
              p.join(
                root,
                book.id,
                'content',
                '${book.contentVersion}',
                'manifest.json',
              ),
            ).existsSync())) {
      return book;
    }
    final path =
        book.localSourcePath ??
        (root == null
            ? null
            : bookSourcePath(p.join(root, book.id), book.format.code));
    if (path == null) return book;
    final source = File(path);
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file) {
      return book.copyWith(status: BookStatus.contentMissing);
    }
    if (book.status == BookStatus.preparing) return book;
    // 没有来源索引的旧正文仍沿用缺失检测，不凭文件时间猜正文是否变化。
    if (root == null) return book;
    final manifest = File(
      p.join(
        root,
        book.id,
        'content',
        '${book.contentVersion}',
        'manifest.json',
      ),
    );
    final manifestStat = await manifest.stat();
    if (manifestStat.type != FileSystemEntityType.file) return book;
    final manifestStamp = _stamp(manifestStat);
    var saved = _indexes[manifest.path];
    if (saved == null || saved.$1 != manifestStamp) {
      // 不在 UI 解码整份目录，也不保留全书章节映射；书架只需要摘要和大小。
      saved = (manifestStamp, await _sourceIndex(manifest.path));
      _indexes[manifest.path] = saved;
    }
    final index = saved.$2;
    if (index == null) return book;
    final (digest, bytes, savedStamp) = index;
    final signature = '$path:${_stamp(stat)}:$digest:$bytes';
    final previous = _verified[book.id];
    if (previous?.$1 == signature) return book.copyWith(status: previous!.$2);
    var status = BookStatus.sourceChanged;
    if (stat.size == bytes) {
      final verification = SourceVerificationRecord(manifest.parent.path);
      if (savedStamp == _stamp(stat) || verification.matches(digest, stat)) {
        _verified[book.id] = (signature, BookStatus.active);
        return book.copyWith(status: BookStatus.active);
      }
      // 大书的 SHA-256 不占 UI 线程，也不同时启动整书库的散列任务。
      final task = _hashing.then((_) => _digestFile(path));
      _hashing = task.then<void>((_) {}, onError: (Object _) {});
      try {
        final actual = await task;
        final after = await source.stat();
        if (after.type != FileSystemEntityType.file) {
          return book.copyWith(status: BookStatus.contentMissing);
        }
        if (_stamp(after) != _stamp(stat)) {
          return book.copyWith(status: BookStatus.sourceChanged);
        }
        if (actual == digest) {
          status = BookStatus.active;
          verification.save(digest, after);
        }
      } on FileSystemException {
        if (!await source.exists()) {
          return book.copyWith(status: BookStatus.contentMissing);
        }
        rethrow;
      }
    }
    _verified[book.id] = (signature, status);
    return book.copyWith(status: status);
  }
}
