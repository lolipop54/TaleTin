import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/exact_page_count.dart';

/// 每章只存各 TXT 小节的页数，普通章只有一个数字。部分完成时也能安全重开。
class BookPageIndex {
  BookPageIndex(this.file, this.geometry);
  final String file, geometry;
  static String fileFor(String cache, String book) => p.join(
    cache,
    'layout_checkpoints',
    sha256.convert(utf8.encode(book)).toString(),
    'page-counts.sqlite',
  );

  List<List<int>> read() {
    final rows = readAll().chapters;
    return [for (var i = 0; rows.containsKey(i); i++) rows[i]!];
  }

  ExactPageCounts readAll() {
    final result = ExactPageCounts();
    if (!File(file).existsSync()) return result;
    final db = sqlite3.open(file, mode: OpenMode.readOnly);
    try {
      db.execute('PRAGMA busy_timeout=3000');
      // 同一个快照读取完整章与零散小节，兼容另一进程此时提交整章。
      db.execute('BEGIN');
      if (db.select("SELECT 1 FROM sqlite_master WHERE name='pages'").isEmpty) {
        return result;
      }
      final rows = db.select(
        'SELECT ordinal, counts FROM pages WHERE geometry = ? ORDER BY ordinal',
        [geometry],
      );
      for (final row in rows) {
        result.chapters[row['ordinal'] as int] =
            (jsonDecode(row['counts'] as String) as List).cast<int>();
      }
      // 旧数据库只有 pages 表，可以直接沿用。
      if (db
          .select("SELECT 1 FROM sqlite_master WHERE name='page_windows'")
          .isNotEmpty) {
        for (final row in db.select(
          'SELECT ordinal, win, offset, windows, pages FROM page_windows WHERE geometry=?',
          [geometry],
        )) {
          result.add(decodeExactPageCount(row.values.toList()));
        }
      }
      return result;
    } finally {
      db.close();
    }
  }

  Database openWriter({int? usedAt}) {
    File(file).parent.createSync(recursive: true);
    final db = sqlite3.open(file);
    db.execute('PRAGMA busy_timeout=3000');
    try {
      db.execute('BEGIN IMMEDIATE');
      db.execute(
        'CREATE TABLE IF NOT EXISTS pages (geometry TEXT, ordinal INTEGER, counts TEXT, PRIMARY KEY (geometry, ordinal))',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS page_windows (geometry TEXT, ordinal INTEGER, win INTEGER, offset INTEGER, windows INTEGER, pages INTEGER, PRIMARY KEY (geometry, ordinal, win))',
      );
      // 用户拖动窗口会产生许多尺寸，只保留最近使用的四套纸面。
      db.execute(
        'CREATE TABLE IF NOT EXISTS layouts (geometry TEXT PRIMARY KEY, used INTEGER)',
      );
      db.execute(
        'INSERT INTO layouts VALUES (?, ?) ON CONFLICT(geometry) DO UPDATE SET used=MAX(used, excluded.used)',
        [geometry, usedAt ?? DateTime.now().microsecondsSinceEpoch],
      );
      db.execute(
        'DELETE FROM layouts WHERE geometry IN (SELECT geometry FROM layouts ORDER BY used DESC LIMIT -1 OFFSET 4)',
      );
      db.execute(
        'DELETE FROM pages WHERE geometry NOT IN (SELECT geometry FROM layouts)',
      );
      db.execute(
        'DELETE FROM page_windows WHERE geometry NOT IN (SELECT geometry FROM layouts)',
      );
      db.execute('COMMIT');
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  void saveBatch(
    Database db,
    int first,
    List<List<int>> chapters, [
    List<ExactPageCount> parts = const [],
  ]) {
    db.execute('BEGIN IMMEDIATE');
    try {
      // 换纸面后旧进程可能稍晚才退出。已被淘汰的版面不能写回孤立页数。
      if (db.select('SELECT 1 FROM layouts WHERE geometry=?', [
        geometry,
      ]).isNotEmpty) {
        for (final part in parts) {
          if (part.windows == 1) {
            db.execute('INSERT OR IGNORE INTO pages VALUES (?, ?, ?)', [
              geometry,
              part.chapter,
              jsonEncode([part.pages]),
            ]);
          } else {
            db.execute(
              'INSERT OR IGNORE INTO page_windows SELECT ?,?,?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM pages WHERE geometry=? AND ordinal=?)',
              [geometry, ...part.toWire(), geometry, part.chapter],
            );
          }
        }
        final insert = db.prepare(
          'INSERT OR IGNORE INTO pages VALUES (?, ?, ?)',
        );
        try {
          for (final windows in chapters) {
            if (windows.length > 1) {
              db.execute(
                'DELETE FROM page_windows WHERE geometry=? AND ordinal=?',
                [geometry, first],
              );
            }
            insert.execute([geometry, first++, jsonEncode(windows)]);
          }
        } finally {
          insert.close();
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

/// 每批从第一章完成时开始计时；读取正文、排版和暂停等待期间都不持有写锁。
class BookPageIndexBatch {
  BookPageIndexBatch(this.index, this.db, this._first);
  final BookPageIndex index;
  final Database db;
  int _first;
  final _rows = <List<int>>[];
  final _parts = <ExactPageCount>[];
  Timer? _timer;
  (Object, StackTrace)? _failure;

  void add(List<int> counts) {
    _rows.add(counts);
    _schedule();
  }

  void addWindow(ExactPageCount part) {
    _parts.add(part);
    _schedule();
  }

  void _schedule() {
    if (_rows.length + _parts.length >= 16) {
      flush();
    } else {
      _timer ??= Timer(const Duration(milliseconds: 250), () {
        try {
          flush();
        } catch (e, s) {
          // 定时回调中的写盘错误要交还给算页任务，并按正常路径释放资源。
          _failure = (e, s);
        }
      });
    }
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
    if (_rows.isEmpty && _parts.isEmpty) return;
    index.saveBatch(db, _first, _rows, _parts);
    _parts.clear();
    _first += _rows.length;
    _rows.clear();
  }
}
