import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:isolate';

import 'package:drift/drift.dart';

import '../../domain/models/backup_operation.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../domain/services/book_progress.dart';
import '../../engine/normalization/text_anchor.dart';
import '../database/app_database.dart';
import '../repositories/file_chapter_content_repository.dart';
import '../../domain/services/library_file_gate.dart';

enum NoteExportFormat {
  markdown('md', 'text/markdown'),
  json('json', 'application/json');

  const NoteExportFormat(this.extension, this.mime);
  final String extension, mime;
}

class ExportedNotes {
  const ExportedNotes(this.file, this.count);
  final File file;
  final int count;
}

/// 同一本书集中输出，书内按创建时间排序；已移除书籍仍保留笔记。
class NotesExportService {
  NotesExportService(this.database, this.work, this.contents, {this.fileGate});
  final AppDatabase database;
  final Directory work;
  final ChapterContentRepository contents;
  final LibraryFileGate? fileGate;

  Future<ExportedNotes> create(
    NoteExportFormat format,
    BackupOperation operation, {
    String? bookId,
  }) async {
    final source = contents;
    if (source is! FileChapterContentRepository) {
      return _create(format, operation, bookId: bookId);
    }
    // 导出独立持有只读正文会话，文件替换必须等它结束；数据库仍复用同一连接和事务。
    final release = await fileGate?.freeze();
    try {
      return await _exportInBackground(
        database,
        work.path,
        source.libraryRoot,
        source.cacheRoot,
        format,
        operation,
        bookId,
      );
    } finally {
      release?.call();
    }
  }

  Future<ExportedNotes> _create(
    NoteExportFormat format,
    BackupOperation operation, {
    String? bookId,
  }) async {
    await work.create(recursive: true);
    final directory = await work.createTemp('notes-');
    final file = File('${directory.path}/阅读笔记.${format.extension}');
    final sink = file.openWrite(encoding: utf8);
    final writer = _NotesWriter(sink, format, _localTime(DateTime.now()));
    final positions = _NotePositions(database, contents);
    var count = 0;
    try {
      await database.transaction(() async {
        final where =
            "a.kind IN ('highlight','note')${bookId == null ? '' : ' AND a.book_id=?'}";
        final filter = [if (bookId != null) Variable<String>(bookId)];
        final total =
            (await database
                    .customSelect(
                      'SELECT COUNT(*) AS n FROM annotations a WHERE $where',
                      variables: filter,
                    )
                    .getSingle())
                .read<int>('n');
        // 同一读取事务内分页；排序先按书分组，再按创建时间，跨批仍接着写同一本书。
        while (count < total) {
          operation.report('整理笔记', count, total);
          final rows = await database
              .customSelect(
                '''SELECT a.book_id, a.created_at, a.chapter_title, a.quote, a.body, a.start_locator_json,
            b.title AS book_title, b.author, b.content_version AS book_version, b.text_length AS book_length
            FROM annotations a JOIN books b ON b.id=a.book_id WHERE $where
            ORDER BY a.book_id, a.created_at, a.id LIMIT 500 OFFSET ?''',
                variables: [...filter, Variable<int>(count)],
              )
              .get();
          for (final row in rows) {
            operation.check();
            final data = row.data;
            final locator = Locator.fromJson(
              (jsonDecode(data['start_locator_json'] as String) as Map)
                  .cast<String, Object?>(),
            );
            final position = await positions.resolve(data, locator);
            operation.check();
            writer.add(
              data['book_id'] as String,
              data['book_title'] as String,
              data['author'] as String,
              locator.chapterId,
              {
                'chapterTitle': data['chapter_title'] ?? '',
                'quote': data['quote'] ?? '',
                'body': data['body'] ?? '',
                'position': position,
                'time': _localTime(
                  DateTime.parse(data['created_at'] as String),
                ),
              },
            );
            count++;
          }
          await sink.flush();
        }
        operation.check();
        writer.finish();
      });
      await sink.flush();
      await sink.close();
      return ExportedNotes(file, count);
    } catch (_) {
      await sink.close();
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}

/// 只读笔记所在章节，用阅读器相同的章节权重和块内偏移计算全书百分比。
class _NotePositions {
  _NotePositions(this.database, this.contents);
  final AppDatabase database;
  final ChapterContentRepository contents;
  String? _bookId, _chapterId;
  List<Chapter> _chapters = [];
  Map<String, int> _chapterIndices = {};
  ChapterContent? _content;

  Future<String> resolve(Map<String, Object?> data, Locator locator) async {
    final bookId = data['book_id'] as String;
    final total = data['book_length'] as int;
    // 移除书籍会清理正文；旧笔记正文版本也可能已失效，不能编造位置。
    if (total <= 0 ||
        locator.needsRelocation ||
        locator.contentVersion != data['book_version']) {
      return '未知';
    }
    if (_bookId != bookId) {
      final rows =
          await (database.select(database.chapters)
                ..where((t) => t.bookId.equals(bookId))
                ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
              .get();
      _chapters = [
        for (final row in rows)
          Chapter(
            id: row.id,
            ordinal: row.ordinal,
            title: row.title,
            contentPath: row.contentPath,
            textLength: row.textLength,
            href: row.href,
          ),
      ];
      _bookId = bookId;
      _chapterIndices = {
        for (var i = 0; i < _chapters.length; i++) _chapters[i].id: i,
      };
      _chapterId = null;
      _content = null;
    }
    final index = _chapterIndices[locator.chapterId] ?? -1;
    if (index < 0) return '未知';
    if (_chapterId != locator.chapterId) {
      _chapterId = locator.chapterId;
      _content = null;
      try {
        // textOnly 不做图片、表格排版，也不读取源 EPUB。
        _content = await contents.chapter(
          bookId,
          _chapters[index],
          textOnly: true,
        );
      } on ContentFailure {
        return '未知';
      } on FileSystemException {
        return '未知';
      }
    }
    final content = _content;
    if (content == null ||
        !content.blocks.any((b) => b.id == locator.blockId)) {
      return '未知';
    }
    final fraction = fractionOfLocator(
      content: content,
      bookId: bookId,
      contentVersion: locator.contentVersion,
      chapterId: locator.chapterId,
      locator: locator,
    );
    return '${(bookProgressAt(_chapters, total, index, fraction) * 100).toStringAsFixed(2)}%';
  }
}

/// 按行写文件，书名／作者和 JSON 的书籍分组不会在每条笔记或每批重复。
class _NotesWriter {
  _NotesWriter(this.sink, this.format, String exportedAt) {
    if (format == NoteExportFormat.json) {
      sink.write('{"exportedAt":${jsonEncode(exportedAt)},"books":[');
    } else {
      sink.write('导出时间：$exportedAt\n\n');
    }
  }
  final IOSink sink;
  final NoteExportFormat format;
  String? _bookId, _chapterKey;
  bool _firstNote = true;

  void add(
    String bookId,
    String title,
    String author,
    String chapterId,
    Map<String, Object?> note,
  ) {
    if (_bookId != bookId) {
      if (format == NoteExportFormat.json) {
        if (_bookId != null) sink.write(']},');
        sink.write(
          '{"bookTitle":${jsonEncode(title)},"author":${jsonEncode(author)},"notes":[',
        );
      } else {
        sink.write(
          '# 《${_escape(title)}》\n作者：${_escape(author.isEmpty ? '未知' : author)}\n\n',
        );
      }
      _bookId = bookId;
      _chapterKey = null;
      _firstNote = true;
    }
    if (format == NoteExportFormat.json) {
      if (!_firstNote) sink.write(',');
      sink.write(jsonEncode(note));
    } else {
      // 时间顺序可能往返不同章节，遇到章节变化再显示标题，不重排笔记。
      final key = '$chapterId\n${note['chapterTitle']}';
      if (_chapterKey != key) {
        sink.write('## ${_escape(note['chapterTitle'])}\n\n');
        _chapterKey = key;
      }
      final quote = _escape(note['quote'])
          .split('\n')
          .map((line) => '> $line')
          .join('\n');
      sink.write(
        '$quote\n\n想法：${_escape(note['body'])}\n\n'
        '位置：${note['position']}  \n时间：${note['time']}\n\n',
      );
    }
    _firstNote = false;
  }

  void finish() {
    if (format == NoteExportFormat.json) {
      if (_bookId != null) sink.write(']}');
      sink.write(']}');
    }
  }
}

String _localTime(DateTime value) =>
    value.toLocal().toIso8601String().replaceFirst('T', ' ').substring(0, 19);
String _escape(Object? value) => '${value ?? ''}'
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAllMapped(RegExp(r'[\\`*_{}\[\]()#+.!|]'), (m) => '\\${m[0]}');

// connect/computation使用独立作用域，防止Dart闭包把主库、进度回调一起捕获。
typedef _ExportInput = (
  String,
  String,
  String?,
  NoteExportFormat,
  String?,
  SendPort,
  String,
);
Future<ExportedNotes> _exportInBackground(
  AppDatabase db,
  String work,
  String library,
  String? cache,
  NoteExportFormat format,
  BackupOperation operation,
  String? bookId,
) async {
  await Directory(work).create(recursive: true);
  operation.check();
  final token = await Directory(work).createTemp('notes-worker-');
  final cancel = '${token.path}/cancel';
  final progress = ReceivePort();
  final sub = progress.listen((dynamic message) {
    final (phase, done, total) = message as (String, int, int);
    operation.onProgress?.call(phase, done, total);
    if (operation.cancelled) File(cancel).writeAsStringSync('cancel');
  });
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (operation.cancelled) File(cancel).writeAsStringSync('cancel');
  });
  try {
    final input = (
      work,
      library,
      cache,
      format,
      bookId,
      progress.sendPort,
      cancel,
    );
    final result = await db.computeWithDatabase(
      connect: AppDatabase.new,
      computation: _exportComputation(input),
    );
    // 很短的导出可能早于取消信号送达；交付前仍检查界面的最终取消状态。
    if (operation.cancelled) {
      await result.file.parent.delete(recursive: true);
      operation.check();
    }
    return result;
  } finally {
    timer.cancel();
    await sub.cancel();
    progress.close();
    await token.delete(recursive: true);
  }
}

Future<ExportedNotes> Function(AppDatabase) _exportComputation(
  _ExportInput input,
) => (db) async {
  final (work, library, cache, format, bookId, progress, cancel) = input;
  final contents = FileChapterContentRepository(
    libraryRoot: library,
    cacheRoot: cache,
  );
  final operation = _NotesOperation(
    cancel,
    onProgress: (phase, done, total) => progress.send((phase, done, total)),
  );
  try {
    return await NotesExportService(
      db,
      Directory(work),
      contents,
    )._create(format, operation, bookId: bookId);
  } finally {
    await contents.close();
  }
};

class _NotesOperation extends BackupOperation {
  _NotesOperation(this.cancelPath, {super.onProgress});
  final String cancelPath;
  @override
  void check() {
    if (File(cancelPath).existsSync()) throw const BackupCancelled();
  }
}
