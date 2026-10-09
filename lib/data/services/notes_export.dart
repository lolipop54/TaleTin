import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import '../../domain/models/backup_operation.dart';
import '../database/app_database.dart';

enum NoteExportFormat {
  markdown('md', 'text/markdown'), json('json', 'application/json');
  const NoteExportFormat(this.extension, this.mime);
  final String extension, mime;
}

class ExportedNotes {
  const ExportedNotes(this.file, this.count);
  final File file;
  final int count;
}

/// 导出数据库中的全部匹配笔记，不受列表分页影响；墓碑书籍仍保留书名。
class NotesExportService {
  NotesExportService(this.database, this.work);
  final AppDatabase database;
  final Directory work;

  Future<ExportedNotes> create(NoteExportFormat format, BackupOperation operation, {String? bookId}) async {
    await work.create(recursive: true);
    final directory = await work.createTemp('notes-');
    final file = File('${directory.path}/阅读笔记.${format.extension}');
    final sink = file.openWrite(encoding: utf8);
    var count = 0;
    try {
      await database.transaction(() async {
        final where = "a.kind IN ('highlight','note')${bookId == null ? '' : ' AND a.book_id=?'}";
        final filter = [if (bookId != null) Variable<String>(bookId)];
        final total = (await database.customSelect('SELECT COUNT(*) AS n FROM annotations a WHERE $where', variables: filter).getSingle()).read<int>('n');
        if (format == NoteExportFormat.json) {
          final header = jsonEncode({'format': 'gtreader-notes', 'formatVersion': 1,
            'exportedAt': DateTime.now().toUtc().toIso8601String(), 'count': total});
          sink.write('${header.substring(0, header.length - 1)},"notes":[');
        } else {
          sink.writeln('# 阅读笔记\n\n共 $total 条高亮和笔记；日期使用 UTC。\n');
        }
        // 同一读取事务内分页，编辑并发发生时也不会重复或漏掉某一条。
        while (count < total) {
          operation.report('整理笔记', count, total);
          final rows = await database.customSelect('''SELECT a.*, b.title AS book_title, b.status AS book_status
            FROM annotations a JOIN books b ON b.id=a.book_id WHERE $where
            ORDER BY a.book_id, a.created_at, a.id LIMIT 500 OFFSET ?''',
            variables: [...filter, Variable<int>(count)]).get();
          for (final row in rows) {
            operation.check();
            final data = row.data;
            final note = <String, Object?>{
              'id': data['id'], 'bookId': data['book_id'], 'bookTitle': data['book_title'],
              'bookStatus': data['book_status'], 'chapterTitle': data['chapter_title'],
              'kind': data['kind'], 'quote': data['quote'], 'body': data['body'],
              'color': data['color_token'],
              'createdAt': DateTime.parse(data['created_at'] as String).toUtc().toIso8601String(),
              'updatedAt': DateTime.parse((data['updated_at'] ?? data['created_at']) as String).toUtc().toIso8601String(),
              'startLocator': jsonDecode(data['start_locator_json'] as String),
              'endLocator': data['end_locator_json'] == null ? null : jsonDecode(data['end_locator_json'] as String),
            };
            if (format == NoteExportFormat.json) {
              if (count > 0) sink.write(',');
              sink.write(jsonEncode(note));
            } else { sink.write(_markdown(note)); }
            count++;
          }
          await sink.flush();
        }
        operation.check();
        if (format == NoteExportFormat.json) sink.write(']}');
      });
      await sink.flush(); await sink.close();
      return ExportedNotes(file, count);
    } catch (_) {
      await sink.close(); await directory.delete(recursive: true); rethrow;
    }
  }
}

String _escape(Object? value) => '${value ?? ''}'.replaceAll('&', '&amp;').replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;').replaceAllMapped(RegExp(r'[\\`*_{}\[\]()#+.!|]'), (m) => '\\${m[0]}');

String _markdown(Map<String, Object?> note) {
  final quote = _escape(note['quote']).split('\n').map((line) => '> $line').join('\n');
  return '## ${_escape(note['bookTitle'])} · ${_escape(note['chapterTitle'])}\n\n'
    '${note['bookStatus'] == 'removed' ? '原书已移除\n\n' : ''}'
    '$quote\n\n${_escape(note['body'])}\n\n'
    '创建：${note['createdAt']}  \n修改：${note['updatedAt']}\n\n'
    '位置（Locator）：\n\n    ${jsonEncode({'start': note['startLocator'], 'end': note['endLocator']})}\n\n';
}
