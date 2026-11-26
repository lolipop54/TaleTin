import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/diagnostics/app_errors.dart';
import '../../domain/models/book.dart';
import '../../domain/models/exact_page_count.dart';
import '../../engine/layout/book_page_options.dart';
import '../../engine/layout/layout_options.dart';
import '../../platform/channels/reading_fonts.dart';
import 'book_page_index.dart';
import 'book_source_path.dart';
import 'publication_cache.dart';
import '../../engine/parsers/epub/publication_section_store.dart';

/// 同一阅读窗口的前台排版和后台算页只交接数字。磁盘读写在独立 isolate。
class ReaderPageCounts {
  ReaderPageCounts(this.library, this.cache);
  final String library, cache;
  final _sessions = <Object, PageCountSession>{};

  final _sourceStamps = Expando<Future<(int, int)>>();

  Future<PageCountSession> session(
    Book book,
    LayoutOptions options, {
    bool refreshSource = false,
  }) async {
    // 同一 Book 对象的排版任务复用文件核验。再次打开计数器时重新检查磁盘原书。
    if (refreshSource) _sourceStamps[book] = null;
    final source = await (_sourceStamps[book] ??= _sourceStamp(library, book));

    final font = await ReadingFonts.spreadFingerprint(
      options.settings.fontFamily,
    );
    final layout = options.layoutSignature;
    final sizes = pageScaleSamples(options.textScaler);
    final key = (
      book.id,
      book.sourceHash,
      book.contentVersion,
      book.chapterCount,
      source,
      font == null ? book : null,
      layout,
      jsonEncode(sizes),
      font,
      ReadingFonts.environmentRevision,
    );
    final cached = _sessions.remove(key);
    final value =
        cached ??
        PageCountSession(
          _geometry(book, source, font, layout, sizes),
          BookPageIndex.fileFor(cache, book.id),
        );
    value.usedAt = DateTime.now().microsecondsSinceEpoch;
    _sessions[key] = value;
    if (_sessions.length > 4) _sessions.remove(_sessions.keys.first);
    return value;
  }

  Future<int?> lookup(
    Book book,
    LayoutOptions options,
    int chapter,
    int window,
    int offset,
    int windows,
  ) async {
    try {
      final counts = await session(book, options);
      return await counts.lookup(chapter, window, offset, windows);
    } catch (e, s) {
      AppErrors.report(e, s, operation: '读取已算小节页数', notify: false);
      return null;
    }
  }

  Future<void> record(
    Book book,
    LayoutOptions options,
    ExactPageCount part,
  ) async {
    try {
      (await session(book, options)).record(part);
    } catch (e, s) {
      AppErrors.report(e, s, operation: '保存前台准确页数', notify: false);
    }
  }
}

class PageCountSession {
  PageCountSession(this.geometry, this.file);
  final String? geometry;
  final String file;
  int usedAt = DateTime.now().microsecondsSinceEpoch;
  final _memory = ExactPageCounts();
  final _events = StreamController<ExactPageCount>.broadcast(sync: true);
  Stream<ExactPageCount> get updates => _events.stream;
  final _pending = <ExactPageCount>[];
  Timer? _timer;
  Future<void> _writes = Future.value();

  void record(ExactPageCount part) {
    if (!_memory.add(part)) return;
    _events.add(part);
    if (geometry == null) return;
    _pending.add(part);
    if (_pending.length >= 16) {
      _flush();
    } else {
      _timer ??= Timer(const Duration(milliseconds: 250), _flush);
    }
  }

  void remember(ExactPageCount part) => _memory.add(part);
  void rememberChapter(int chapter, List<int> counts) =>
      _memory.chapters[chapter] = counts;

  Future<void> flush() {
    if (_pending.isNotEmpty) _flush();
    return _writes;
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    final rows = _pending.toList();
    _pending.clear();
    final index = BookPageIndex(file, geometry!);
    final stamp = usedAt;
    _writes = _writes.then((_) => _write(index, rows, stamp)).catchError((
      Object e,
      StackTrace s,
    ) {
      AppErrors.report(e, s, operation: '保存前台准确页数', notify: false);
    });
  }

  Future<void>? _loading;
  Future<void> _load() async {
    if (geometry == null) return;
    final disk = await _read(BookPageIndex(file, geometry!));
    for (final part in disk.partialWindows) {
      _memory.add(part);
    }
    _memory.chapters.addAll(disk.chapters);
  }

  Future<int?> lookup(int chapter, int window, int offset, int windows) async {
    final hit = _memory.lookup(chapter, window, offset, windows);
    if (hit != null) return hit;
    await (_loading ??= _load());
    return _memory.lookup(chapter, window, offset, windows);
  }

  Future<int?> chapterTotal(int chapter) async {
    final counts = _memory.chapters[chapter];
    if (counts != null) return counts.fold<int>(0, (sum, pages) => sum + pages);
    await (_loading ??= _load());
    return _memory.chapters[chapter]?.fold<int>(0, (sum, pages) => sum + pages);
  }

  Future<ExactPageCounts> saved() async {
    // 新后台任务重读磁盘。上个进程退出时可能提交了还没发到窗口的小节。
    await (_loading = _load());
    return _memory;
  }
}

Future<ExactPageCounts> _read(BookPageIndex index) =>
    Isolate.run(index.readAll);
Future<void> _write(
  BookPageIndex index,
  List<ExactPageCount> rows,
  int usedAt,
) => Isolate.run(() {
  final db = index.openWriter(usedAt: usedAt);
  try {
    index.saveBatch(db, 0, [], rows);
  } finally {
    db.close();
  }
});

Future<(int, int)> _sourceStamp(String library, Book book) => Isolate.run(() {
  final source = File(
    bookSourcePath(p.join(library, book.id), book.format.code),
  ).statSync();
  return (source.size, source.modified.microsecondsSinceEpoch);
});

String? _geometry(
  Book book,
  (int, int) source,
  String? font,
  String layout,
  Object? sizes,
) {
  if (font == null) return null;

  final key = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            1,
            book.contentVersion,
            book.sourceHash,
            source.$1,
            source.$2,
            book.chapterCount,
            PublicationCache.contentRevision,
            if (book.format.usesOriginalWebView) PublicationSectionStore.folder,
            Platform.localeName,
            Platform.operatingSystemVersion,
            layout,
            sizes,
            font,
            const String.fromEnvironment('FLUTTER_ENGINE_REVISION'),
          ]),
        ),
      )
      .toString();
  return key;
}
