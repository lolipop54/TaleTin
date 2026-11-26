import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/book.dart';
import '../../domain/models/exact_page_count.dart';
import '../../domain/models/book_document.dart';
import '../../domain/services/library_file_gate.dart';
import '../../domain/services/chapter_sections.dart';
import '../../engine/layout/book_page_options.dart';
import '../../engine/layout/chapter_layout.dart';
import '../../engine/layout/math_formula.dart';
import '../../engine/layout/math_typesetting.dart';
import '../../engine/parsers/txt_text_preparation.dart';
import '../../platform/channels/android_document_platform.dart';
import '../../platform/channels/reading_fonts.dart';
import '../repositories/file_chapter_content_repository.dart';
import 'book_page_index.dart';
import 'epub_source_repository.dart';
import 'flutter_tex_formula_renderer.dart';
import 'imported_font_store.dart';
import 'publication_font_loader.dart';

const bookPageChannel = MethodChannel('gtreader/book_pages');

class _ReadAheadMemory with WidgetsBindingObserver {
  _ReadAheadMemory(this.enabled);
  bool enabled;

  @override
  void didHaveMemoryPressure() => enabled = false;
}

/// Windows 算页进程没有阅读窗口。公式使用阅读窗口的转换器和缓存，
/// 这里只接收测量需要的尺寸、基线和资源名。
class _WindowsPageFormulaRenderer implements FormulaRenderer {
  _WindowsPageFormulaRenderer(this.socket);

  final Socket socket;
  final _pending = <int, Completer<RenderedFormula>>{};
  var _nextId = 0;
  var _closed = false;

  @override
  Future<RenderedFormula> render(String xml) async {
    if (_closed) throw const LayoutCancelled();
    final id = ++_nextId;
    final result = _pending[id] = Completer<RenderedFormula>();
    try {
      socket.writeln(jsonEncode(['formula', id, xml]));
      return await result.future;
    } finally {
      _pending.remove(id);
    }
  }

  void receive(List reply) {
    final result = _pending.remove(reply[1] as int);
    if (result == null) return;
    final metrics = reply[2] as List?;
    if (metrics == null) {
      result.completeError(StateError(reply[3] as String));
      return;
    }
    result.complete(
      RenderedFormula(
        resource: metrics[0] as String,
        width: (metrics[1] as num).toDouble(),
        height: (metrics[2] as num).toDouble(),
        baseline: (metrics[3] as num).toDouble(),
      ),
    );
  }

  void close() {
    _closed = true;
    for (final result in _pending.values) {
      result.completeError(const LayoutCancelled());
    }
    _pending.clear();
  }
}

/// 在独立进程的根 isolate 中运行。仅接受启动者建立的本机连接。
Future<void> runBookPageWorker(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final port = int.parse(args[0]);
  final ticket = args[1];
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.writeln(ticket);
    final windowsMath = Platform.isWindows
        ? _WindowsPageFormulaRenderer(socket)
        : null;
    final request = Completer<Map<String, dynamic>>();
    var closed = false, paused = false;
    final known = ExactPageCounts();
    void disconnected() {
      closed = true;
      windowsMath?.close();
      if (!request.isCompleted) request.completeError(const LayoutCancelled());
    }

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!request.isCompleted) {
              request.complete(jsonDecode(line) as Map<String, dynamic>);
            } else if (line == 'pause' || line == 'resume') {
              paused = line == 'pause';
            } else {
              final data = jsonDecode(line) as List;
              if (data.first == 'formula') {
                windowsMath!.receive(data);
              } else {
                known.add(decodeExactPageCount(data));
              }
            }
          },
          onDone: disconnected,
          onError: (Object _) => disconnected(),
        );
    final memory = _ReadAheadMemory(!args.skip(2).contains('serial'));
    WidgetsBinding.instance.addObserver(memory);
    try {
      await _countBook(
        await request.future,
        known,
        (data) {
          if (!closed) socket!.writeln(jsonEncode(data));
        },
        (flush) async {
          await Future<void>.delayed(Duration.zero);
          if (paused || closed) flush();
          while (paused && !closed) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          if (closed) throw const LayoutCancelled();
        },
        () => memory.enabled && !paused && !closed,
        windowsMath ?? FlutterTexFormulaRenderer(),
      );
    } finally {
      WidgetsBinding.instance.removeObserver(memory);
    }
  } on LayoutCancelled {
    // 阅读器已经切书、调整版面或退出。
  } catch (error, stack) {
    socket?.writeln(jsonEncode(['error', '$error', '$stack']));
  } finally {
    try {
      await socket?.flush();
      await socket?.close();
    } on SocketException {
      socket?.destroy();
    }
    if (Platform.isAndroid) {
      await bookPageChannel.invokeMethod<void>('finished', ticket);
    } else {
      exit(0);
    }
  }
}

Future<void> _countBook(
  Map<String, dynamic> job,
  ExactPageCounts known,
  void Function(List<Object?>) send,
  Future<void> Function(void Function()) handleControls,
  bool Function() allowReadAhead,
  FormulaRenderer formulas,
) async {
  for (final row in (job['knownRows'] as List? ?? const [])) {
    known.chapters[row[0] as int] = (row[1] as List).cast<int>();
  }
  for (final part in (job['known'] as List? ?? const [])) {
    known.add(decodeExactPageCount(part));
  }
  final id = job['book'] as String;
  final version = job['version'] as int;
  final format = BookFormat.fromCode(job['format'])!;
  final library = job['library'] as String, cache = job['cache'] as String;
  final options = decodePageOptions(job['options']);
  final chapters = [
    for (final c in job['chapters'])
      Chapter(
        id: c[0],
        ordinal: c[1],
        title: c[2],
        contentPath: c[3],
        textLength: c[4],
        href: c[5],
      ),
  ];
  final scratchParent = await Directory(p.join(cache, 'page-count-work'))
      .create(recursive: true);
  final scratch = await scratchParent.createTemp('reading-');
  final contents = FileChapterContentRepository(
    libraryRoot: library,
    cacheRoot: scratch.path,
    pageCountReadCache: cache,
    cacheCapacity: 1,
    textPreparation: TxtTextPreparation(platform: AndroidDocumentPlatform()),
  );
  final sources = EpubSourceRepository(
    libraryRoot: library,
    cacheRoot: scratch.path,
  );
  final fonts = PublicationFontLoader(
    (_) => sources.open(
      bookId: id,
      contentVersion: version,
      chapters: chapters,
      fontsOnly: true,
    ),
    sourceIdentity: (_, _) async => version,
  );
  final releaseFonts = fonts.retainBook(
    Book(
      id: id,
      sourceHash: '',
      title: '',
      author: '',
      format: format,
      importedAt: DateTime.fromMillisecondsSinceEpoch(0),
      contentVersion: version,
    ),
  );
  final index = job['geometry'] == null
      ? null
      : BookPageIndex(BookPageIndex.fileFor(cache, id), job['geometry']);
  final first = job['start'] as int;
  BookPageIndexBatch? batch;
  Future<void> yieldToControls() => handleControls(() => batch?.flush());
  Future<(ChapterSections?, ChapterContent?)> read(Chapter chapter) async {
    final sections = await contents.chapterSections(id, chapter, format);
    return (
      sections,
      sections == null ? await contents.chapter(id, chapter) : null,
    );
  }

  Future<(ChapterSections?, ChapterContent?)>? next;
  var total = job['total'] as int, previous = total;
  final completed = <List<int>>[];
  final newWindows = <int>[];
  final exactWindows = <List<int>>[];
  void publish() {
    if (exactWindows.isNotEmpty) {
      send(['windows', exactWindows]);
      exactWindows.clear();
    }
    if (previous == total && completed.isEmpty && newWindows.isEmpty) return;
    send(['progress', total, completed, newWindows]);
    completed.clear();
    newWindows.clear();
    previous = total;
  }

  final timer = Timer.periodic(
    const Duration(milliseconds: 80),
    (_) => publish(),
  );
  try {
    if (index != null) {
      batch = BookPageIndexBatch(
        index,
        index.openWriter(usedAt: job['usedAt'] as int?),
        first,
      );
    }
    final imported = job['imported'] as String?;
    if (imported != null) {
      ReadingFonts.configureImported(
        ImportedFontStore(Directory(imported), LibraryFileGate()),
      );
    }
    await ReadingFonts.loadSystem();
    await ReadingFonts.loadSelected(options.settings.fontFamily);
    MathTypesetting.cacheRoot =
        job['math'] ?? p.join(cache, 'formula-${MathTypesetting.revision}');
    MathTypesetting.renderer = formulas;
    for (var i = first; i < chapters.length; i++) {
      await yieldToControls();
      final chapter = chapters[i];
      final saved = known.chapters[i];
      if (saved != null) {
        // 前台在预读开始后完成时，等待该读操作收尾，再继续目录里的下一章。
        if (next != null) {
          await next.then<void>((_) {}, onError: (Object _) {});
          next = null;
        }
        total += saved.fold(0, (a, b) => a + b);
        completed.add(saved);
        batch?.add(saved);
        newWindows.clear();
        continue;
      }
      final input = next ?? read(chapter);
      next = null;
      final (sections, body) = await input;
      final actual = body == null
          ? options
          : await fonts.prepare(id, body, options);
      // 两个大章不同时驻留。长 TXT 的小节也继续按需读取，与下一章互不争用。
      if (allowReadAhead() &&
          i + 1 < chapters.length &&
          !known.chapters.containsKey(i + 1) &&
          chapter.textLength < kLongTxtChapterLength &&
          chapters[i + 1].textLength < kLongTxtChapterLength) {
        next = read(chapters[i + 1]);
        // 错误在轮到这章时上报。若中途退出，先等这笔读取结束，再关闭仓库。
        next.ignore();
      }
      final counts = await countChapterPages(
        input: (
          bookId: id,
          version: version,
          chapter: chapter,
          content: body,
          sections: sections,
          options: actual,
        ),
        prepareSectionOptions:
            sections == null || !options.settings.useBookFontsInSimplified
            ? null
            : (body) => fonts.prepare(id, body, options),
        onCount: (pages) => total += pages,
        knownPages: (window, offset, windows) =>
            known.lookup(i, window, offset, windows),
        onExactWindow: (part) {
          exactWindows.add(part.toWire());
          batch?.addWindow(part);
        },
        onWindowComplete: newWindows.add,
        yieldToControls: yieldToControls,
      );
      batch?.add(counts);
      completed.add(counts);
      // 完整章已包含所有小节，本次刷新只额外发送下一未完章的小节增量。
      newWindows.clear();
    }
    batch?.flush();
    publish();
    send(['done', total]);
  } finally {
    timer.cancel();
    try {
      batch?.flush();
    } finally {
      batch?.db.close();
      if (next != null) await next.then<void>((_) {}, onError: (Object _) {});
      releaseFonts();
      await contents.close();
      await sources.close();
      await scratch.delete(recursive: true);
    }
  }
}
