import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/diagnostics/app_errors.dart';
import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../engine/layout/book_page_options.dart';
import '../../engine/layout/chapter_layout.dart';
import '../../engine/layout/layout_options.dart';
import '../../engine/layout/math_typesetting.dart';
import '../../platform/channels/imported_fonts.dart';
import '../../domain/models/exact_page_count.dart';
import 'reader_page_counts.dart';
import 'book_page_worker.dart' show bookPageChannel;

/// 仅页脚监听。前台保存各章和 TXT 小节的累计页数，不持有后台量出的文字或图片。
class BookPageCounter extends ChangeNotifier {
  BookPageCounter({this._shared});
  final ReaderPageCounts? _shared;
  StreamSubscription<ExactPageCount>? _updates;
  PageCountSession? _session;
  final _pending = <ExactPageCount>[];
  final _starts = <int>[0];
  final _sections = <List<int>>[];
  final _liveSectionStarts = <int>[0];
  int total = 0;
  bool indexReady = false;
  bool get paused => _paused;
  bool complete = false, failed = false, _closed = false, _paused = false;
  Socket? _peer;
  Process? _startingWorker;
  bool _workerConnected = false;
  ServerSocket? _server;
  Timer? _timeout;
  final _clients = <Socket>{};

  int? number(int chapter, ChapterLayout layout, int page) {
    if (chapter < 0 || chapter >= _starts.length) return null;
    final window = layout.sectionIndex;
    if (window == null) return _starts[chapter] + page + 1;
    // 长 TXT 的同一章可能分成许多小节，翻到后面的小节也能在整章结束前显示页号。
    final starts = chapter < _sections.length
        ? _sections[chapter]
        : _liveSectionStarts;
    if (window >= starts.length) return null;
    return _starts[chapter] + starts[window] + page - layout.firstPage + 1;
  }

  void pause(bool value) {
    if (_paused == value || _closed || complete || failed) return;
    _paused = value;
    if (value) unawaited(_session?.flush());
    _peer?.writeln(value ? 'pause' : 'resume');
  }

  void _append(List rows) {
    for (final row in rows.cast<List>()) {
      final starts = <int>[0];
      for (final pages in row.cast<int>()) {
        starts.add(starts.last + pages);
      }
      _sections.add(starts);
      _starts.add(_starts.last + starts.last);
    }
  }

  Future<void> start(
    Book book,
    List<Chapter> chapters,
    LayoutOptions options,
    String library,
    String cache,
  ) async {
    try {
      final wire = encodePageOptions(options);
      final store = _shared ?? ReaderPageCounts(library, cache);
      final session = await store.session(book, options, refreshSource: true);
      if (_closed) return;
      _session = session;
      final known = await session.saved();
      if (_closed) return;
      final saved = [
        for (var i = 0; known.chapters.containsKey(i); i++) known.chapters[i]!,
      ];
      _updates = session.updates.listen((part) {
        if (_closed || complete || failed) return;
        final peer = _peer;
        if (peer == null) {
          _pending.add(part);
        } else {
          peer.writeln(jsonEncode(part.toWire()));
        }
      });
      _append(saved);
      indexReady = true;
      total = _starts.last;
      complete = saved.length == chapters.length;
      notifyListeners();
      if (complete || _closed) return;
      final job = <String, dynamic>{
        'library': library,
        'cache': cache,
        'book': book.id,
        'version': book.contentVersion,
        'format': book.format.code,
        'options': wire,
        'geometry': session.geometry,
        'usedAt': session.usedAt,
        'knownRows': [
          for (final e in known.chapters.entries)
            if (e.key >= saved.length) [e.key, e.value],
        ],
        'known': [
          for (final part in known.partialWindows)
            if (!known.chapters.containsKey(part.chapter)) part.toWire(),
        ],
        'total': total,
        'start': saved.length,
        'math': MathTypesetting.cacheRoot,
        'imported': ImportedFonts.store?.directory.path,
      };
      final bytes = await _encodeJob(job, chapters);
      if (_closed) return;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      if (_closed) {
        await server.close();
        return;
      }
      _server = server;
      final random = Random.secure();
      final ticket = base64Url.encode(
        List.generate(32, (_) => random.nextInt(256)),
      );
      server.listen(
        (socket) =>
            acceptWorkerConnection(socket, ticket, bytes, chapters.length),
        onError: (Object e, StackTrace s) => _fail(e, s),
      );
      _timeout = Timer(
        const Duration(seconds: 25),
        () => _fail(TimeoutException('排版进程启动超时'), StackTrace.current),
      );
      if (Platform.isAndroid) {
        await bookPageChannel.invokeMethod<void>('start', {
          'port': server.port,
          'ticket': ticket,
        });
      } else {
        final process = await Process.start(Platform.resolvedExecutable, [
          '--book-page-worker',
          '${server.port}',
          ticket,
        ], mode: ProcessStartMode.normal);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        // 窗口换尺寸时启动可能尚未返回。未接单的 Windows 子进程还没有
        // 拿到书库路径，可以直接收回；已接单的进程通过断开连接保存并退出。
        if (!_workerConnected) {
          if (_closed || failed) {
            process.kill();
          } else {
            _startingWorker = process;
          }
        }
        // 连接建立前发生启动错误时也能收起计算提示。
        unawaited(
          process.exitCode.then((code) {
            _startingWorker = null;
            if (_peer == null && !_closed && !complete) {
              _fail(StateError('排版进程已退出 ($code)'), StackTrace.current);
            }
          }),
        );
      }
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  @visibleForTesting
  void acceptWorkerConnection(
    Socket socket,
    String ticket,
    Uint8List job,
    int chapters,
  ) {
    if (_closed || failed) {
      socket.destroy();
      return;
    }
    _clients.add(socket);
    var authenticated = false;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (_closed || failed) return;
            if (!authenticated) {
              if (line != ticket || _peer != null) {
                socket.destroy();
                return;
              }
              authenticated = true;
              _workerConnected = true;
              _startingWorker = null;
              _peer = socket;
              _timeout?.cancel();
              unawaited(_server?.close());
              socket.add(job);
              for (final part in _pending) {
                socket.writeln(jsonEncode(part.toWire()));
              }
              _pending.clear();
              if (_paused) socket.writeln('pause');
              return;
            }
            try {
              final event = jsonDecode(line) as List;
              switch (event.first) {
                case 'formula':
                  unawaited(
                    _renderWorkerFormula(
                      socket,
                      event[1] as int,
                      event[2] as String,
                    ),
                  );
                  return;
                case 'windows':
                  for (final row in event[1] as List) {
                    _session?.remember(decodeExactPageCount(row));
                  }
                  return;
                case 'progress':
                  final rows = event[2] as List;
                  if (rows.isNotEmpty) _liveSectionStarts.length = 1;
                  for (var i = 0; i < rows.length; i++) {
                    _session?.rememberChapter(
                      _sections.length + i,
                      (rows[i] as List).cast<int>(),
                    );
                  }
                  _append(rows);
                  for (final pages in (event[3] as List).cast<int>()) {
                    _liveSectionStarts.add(_liveSectionStarts.last + pages);
                  }
                  total = event[1] as int;
                case 'done':
                  if (_sections.length != chapters ||
                      _starts.last != event[1]) {
                    throw StateError('后台页数与完成的章节不一致');
                  }
                  complete = true;
                  total = _starts.last;
                case 'error':
                  _fail(
                    StateError(event[1] as String),
                    StackTrace.fromString(event[2] as String),
                  );
                  return;
              }
              notifyListeners();
            } catch (e, s) {
              _fail(e, s);
            }
          },
          onError: (Object e, StackTrace s) {
            if (authenticated) _fail(e, s);
          },
          onDone: () {
            _clients.remove(socket);
            if (identical(_peer, socket)) _peer = null;
            if (authenticated && !complete && !failed) {
              _fail(StateError('排版连接已关闭'), StackTrace.current);
            }
            socket.destroy();
          },
        );
  }

  Future<void> _renderWorkerFormula(Socket socket, int id, String xml) async {
    List<Object?>? metrics;
    String? failure;
    try {
      final formula = await MathTypesetting.renderer!.render(xml);
      metrics = [
        formula.resource,
        formula.width,
        formula.height,
        formula.baseline,
      ];
    } on Object catch (error) {
      failure = '$error';
    }
    if (identical(socket, _peer)) {
      socket.writeln(jsonEncode(['formula', id, metrics, failure]));
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (_closed || failed || complete) return;
    failed = true;
    _disconnect();
    AppErrors.report(error, stack, operation: '全书页码计算失败', notify: false);
    notifyListeners();
  }

  void _disconnect() {
    unawaited(_session?.flush());
    unawaited(_updates?.cancel());
    _pending.clear();
    _timeout?.cancel();
    _startingWorker?.kill();
    _startingWorker = null;
    unawaited(_server?.close());
    // Windows 的 destroy 可以同步触发 onDone。先取走这批连接，避免
    // onDone 删除正被遍历的元素，导致页脚卸载中断、阅读窗口卡在旧画面。
    final closing = _clients.toList(growable: false);
    _clients.clear();
    _peer = null;
    for (final socket in closing) {
      socket.destroy();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _disconnect();
    super.dispose();
  }
}

Future<Uint8List> _encodeJob(
  Map<String, dynamic> job,
  List<Chapter> chapters,
) => Isolate.run(() {
  // 仅传章节目录，不把任何正文从阅读窗口复制给后台。
  job['chapters'] = [
    for (final c in chapters)
      [c.id, c.ordinal, c.title, c.contentPath, c.textLength, c.href],
  ];
  return utf8.encode('${jsonEncode(job)}\n');
});
