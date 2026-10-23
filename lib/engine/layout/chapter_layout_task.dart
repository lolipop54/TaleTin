part of 'chapter_layout.dart';

/// 同参数只有一个迭代器。目标请求可取消，但不会销毁其他消费者需要的页面。
class ChapterLayoutTask {
  ChapterLayoutTask({
    required this.bookId,
    required this.contentVersion,
    required this.chapter,
    required this.content,
    required this.options,
    BlockMeasurementCache? measurementCache,
    this.onCheckpoint,
    this.readCheckpoint,
  }) {
    _source = _LazyMeasuredBlocks(
      chapter,
      content,
      options,
      measurementCache,
      cacheEnabled: onCheckpoint != null,
    );
    _steps = ChapterPaginator(
      pageHeight: options.contentHeight,
      gapBefore: _source.measurer.gapBefore,
    ).steps(_source).iterator;
    _mapper = LocatorMapper(
      bookId: bookId,
      contentVersion: contentVersion,
      chapterId: chapter.id,
    );
    _totalLength = _mapper.totalLength(content.blocks);
  }

  final String bookId;
  final int contentVersion;
  final Chapter chapter;
  final ChapterContent content;
  final LayoutOptions options;
  final void Function(Map<String, Object?>)? onCheckpoint;
  final Future<Map<String, dynamic>?> Function(
    int? throughCursor,
    int afterBlocks,
  )?
  readCheckpoint;
  late final _LazyMeasuredBlocks _source;
  late final Iterator<PageSlice?> _steps;
  late final LocatorMapper _mapper;
  late final int _totalLength;
  final _pages = <PageSlice>[];
  final _events = StreamController<ChapterLayout>.broadcast(sync: true);
  Future<void> _flight = Future.value();
  bool _complete = false,
      _disposed = false,
      _background = false,
      _wantBackground = false;
  Object? _failure;
  int _foreground = 0;
  int _savedPages = 0;
  Timer? _timer;
  Completer<void>? _wake;
  ChapterLayout? _snapshot;
  Stream<ChapterLayout> get updates => _events.stream;
  bool get isInUse => _foreground > 0 || _wantBackground;
  int _maxStepUs = 0;
  bool _cacheMore = true;

  Future<void> _restoreTo(int? cursor) async {
    if (readCheckpoint == null ||
        !_cacheMore ||
        (cursor != null && cursor <= _source.cursor)) {
      return;
    }
    final data = await readCheckpoint!(cursor, _source.values.length);
    if (_disposed) throw const LayoutCancelled();
    final trace = ReaderWorkTrace.start('layout.checkpoint.restore', {
      'chapter': chapter.ordinal,
      'throughCursor': cursor,
    });
    try {
      final restored = data != null && _source.restore(data);
      _cacheMore = restored && data['_hasMore'] == true;
      trace?.details.addAll({
        'restored': restored,
        'blocks': _source.values.length,
        'cursor': _source.cursor,
      });
      if (restored) _snapshot = null;
    } finally {
      trace?.finish();
    }
  }

  bool restoreCheckpoint(Map<String, dynamic> data) {
    if (_pages.isNotEmpty) return false;
    try {
      return _source.restore(data);
    } on Object {
      return false;
    }
  }

  void _saveCheckpoint() {
    if (onCheckpoint == null || _source.encoded.isEmpty) return;
    _savedPages = _pages.length;
    onCheckpoint!({
      'cursor': _source.cursor,
      'blocks': List.of(_source.encoded),
    });
  }

  ChapterLayout get snapshot => _snapshot ??= ChapterLayout._(
    bookId: bookId,
    contentVersion: contentVersion,
    chapterId: chapter.id,
    chapterTitle: chapter.title,
    blocks: List.unmodifiable(_source.values),
    pages: List.unmodifiable(_pages),
    mapper: _mapper,
    totalLength: _totalLength,
    content: content,
    options: options,
    task: this,
    isComplete: _complete,
    // 只追加索引，不修改既有页或块顺序。旧快照未覆盖的目标仍返回 null。
    measuredById: _source.measuredById,
    blockOrders: _source.orders,
  );

  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _flight.then((_) => work());
    _flight = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  bool _step() {
    if (_disposed) throw const LayoutCancelled();
    if (_failure != null) throw _failure!;
    if (_complete) return false;
    final watch = readerWorkTraceEnabled ? (Stopwatch()..start()) : null;
    final moved = _steps.moveNext();
    if (watch != null && watch.elapsedMicroseconds > _maxStepUs) {
      _maxStepUs = watch.elapsedMicroseconds;
    }
    if (!moved) {
      _complete = true;
      _snapshot = null;
      return false;
    }
    final page = _steps.current;
    if (page != null) {
      _pages.add(page);
      _snapshot = null;
    }
    return true;
  }

  /// 请求页与直接后页。前页已在确定的前缀里；真正章末必须推进至 EOF。
  Future<ChapterLayout> ensure({
    Locator? target,
    int? page,
    bool atEnd = false,
    LayoutToken? token,
    int lookAhead = 4,
  }) async {
    _foreground++;
    try {
      return await _serial(() async {
        await EnglishHyphenation.prepare();
        if (atEnd) {
          await _restoreTo(null);
        } else if (target != null) {
          final index = content.blocks.indexWhere(
            (b) => b.id == target.blockId,
          );
          if (index >= 0) await _restoreTo(index + 1);
        } else if (_pages.length <= (page ?? 0)) {
          await _restoreTo(_source.cursor + 1);
        }
        final trace = ReaderWorkTrace.start('layout.window', {
          'chapter': chapter.ordinal,
          'blocks': content.blocks.length,
          'atEnd': atEnd,
        });
        final batch = Stopwatch()..start();
        try {
          while (true) {
            if (token?.isCancelled ?? false) throw const LayoutCancelled();
            final index = target == null
                ? page ?? 0
                : snapshot.pageIndexOf(target);
            if (_complete ||
                (!atEnd &&
                    index != null &&
                    _pages.length > index + lookAhead)) {
              break;
            }
            if (_source.needsCachedRows) await _restoreTo(_source.cursor + 1);
            _step();
            if (batch.elapsedMicroseconds >= 2000) {
              await Future<void>.delayed(Duration.zero);
              batch.reset();
            }
          }
          trace?.details.addAll({
            'pages': _pages.length,
            'complete': _complete,
            'measuredBlocks': _source.values.length,
            'maxStepUs': _maxStepUs,
          });
          if (_complete || _pages.length - _savedPages >= 48) _saveCheckpoint();
          return snapshot;
        } finally {
          trace?.finish();
        }
      });
    } finally {
      _foreground--;
    }
  }

  void resumeBackground() {
    _wantBackground = true;
    if (_background || _complete || _disposed) return;
    _background = true;
    unawaited(_pump());
  }

  void pauseBackground() {
    _wantBackground = false;
    _timer?.cancel();
    if (_wake?.isCompleted == false) _wake!.complete();
  }

  Future<void> _pump() async {
    var published = _pages.length;
    var saved = _pages.length;
    try {
      while (_wantBackground && !_complete && !_disposed) {
        final wake = _wake = Completer<void>();
        _timer = Timer(const Duration(milliseconds: 8), () {
          if (!wake.isCompleted) wake.complete();
        });
        await wake.future;
        if (!_wantBackground || _disposed) break;
        if (LayoutWorkGate.blocked || _foreground > 0) continue;
        await _serial(() async {
          final batch = Stopwatch()..start();
          while (_wantBackground &&
              !_complete &&
              !_disposed &&
              !LayoutWorkGate.blocked &&
              _foreground == 0) {
            if (_source.needsCachedRows) await _restoreTo(_source.cursor + 1);
            if (LayoutWorkGate.blocked || _foreground > 0 || !_wantBackground) {
              break;
            }
            _step();
            if (batch.elapsedMicroseconds >= 1500) break;
          }
        });
        if (!_disposed && (_complete || _pages.length - published >= 12)) {
          published = _pages.length;
          _events.add(snapshot);
          if (_complete || _pages.length - saved >= 48) {
            saved = _pages.length;
            _saveCheckpoint();
          }
        }
      }
    } catch (error) {
      // 已显示页面继续有效；下次请求缺失页时明确返回原失败，不能伪报 EOF。
      if (error is! LayoutCancelled) _failure = error;
    } finally {
      _background = false;
      if (_wantBackground && !_complete && !_disposed && _failure == null) {
        resumeBackground();
      }
    }
  }

  void dispose() {
    _disposed = true;
    pauseBackground();
    unawaited(_events.close());
  }
}

class _LazyMeasuredBlocks implements MeasuredBlockSource {
  _LazyMeasuredBlocks(
    this.chapter,
    this.content,
    this.options,
    BlockMeasurementCache? cache, {
    required this.cacheEnabled,
  }) : measurementCache = cache,
       measurer = BlockMeasurer(options, cache: cache) {
    _byId = {for (final b in content.blocks) b.id: b};
    _tables = {for (final t in content.tables) t.blockIds.first: t};
    _tableIds = content.tables.expand((t) => t.blockIds).toSet();
    _contentTitle = ChapterLayout.firstBlockIsChapterTitle(
      content,
      chapter.title,
    );
  }
  final Chapter chapter;
  final ChapterContent content;
  final LayoutOptions options;
  final BlockMeasurer measurer;
  final BlockMeasurementCache? measurementCache;
  final bool cacheEnabled;
  final values = <MeasuredBlock>[];
  final measuredById = <String, MeasuredBlock>{};
  final orders = <String, int>{};
  final encoded = <Map<String, Object?>>[];
  late final Map<String, ContentBlock> _byId;
  late final Map<String, ContentTable> _tables;
  late final Set<String> _tableIds;
  late final bool _contentTitle;
  var _cursor = 0;
  bool _started = false;
  int _requested = -1;
  int get cursor => _cursor;
  bool get needsCachedRows => values.length - _requested <= 3;

  void _add(MeasuredBlock block, {bool inTable = false}) {
    measuredById.putIfAbsent(block.blockId, () => block);
    orders.putIfAbsent(block.blockId, () => values.length);
    values.add(block);
    if (cacheEnabled) {
      encoded.add({
        ...MeasuredBlockCodec.encode(block),
        'sourceCursor': inTable ? null : _cursor,
      });
    }
  }

  bool restore(Map<String, dynamic> checkpoint) {
    final cursor = checkpoint['cursor'] as int;
    if (cursor < _cursor ||
        cursor > content.blocks.length ||
        (checkpoint['_from'] as int? ?? 0) != values.length) {
      return false;
    }
    final raw = (checkpoint['blocks'] as List)
        .map((x) => Map<String, dynamic>.from(x as Map))
        .toList();
    final restored = raw.map(MeasuredBlockCodec.decode).toList();
    final allowed = {
      BlockMeasurer.titleBlockId,
      ...content.blocks.take(cursor).map((b) => b.id),
    };
    // 表格按整体测量：游标刚越过首格时，后面格子的测量也已经完成。
    for (final table in content.tables) {
      if (!allowed.contains(table.blockIds.first)) continue;
      allowed.addAll(table.blockIds);
      for (final cell in table.cells.where((c) => c.blocks.isEmpty)) {
        allowed.add(
          '__empty_${table.blockIds.first}_${cell.row}_${cell.column}',
        );
      }
    }
    if (restored.any((b) => !allowed.contains(b.blockId))) {
      return false;
    }
    for (final block in restored) {
      measuredById.putIfAbsent(block.blockId, () => block);
      orders.putIfAbsent(block.blockId, () => values.length);
      values.add(block);
    }
    if (cacheEnabled) encoded.addAll(raw);
    _cursor = cursor;
    _started = true;
    return true;
  }

  @override
  bool has(int index) {
    if (index > _requested) _requested = index;
    if (!_started) {
      _started = true;
      // PDF的章节只是用于定位的物理页，不把“第N页”插入电子书正文。
      if (content.pdfPage == null && !_contentTitle && chapter.title.trim().isNotEmpty) {
        _add(measurer.measureChapterTitle(chapter.title));
      }
    }
    while (values.length <= index && _cursor < content.blocks.length) {
      final ordinal = _cursor++;
      final block = content.blocks[ordinal];
      final table = _tables[block.id];
      if (table != null) {
        final before = encoded.length;
        for (final measured in measureTable(
          table,
          _byId,
          options,
          cache: measurementCache,
        )) {
          _add(measured, inTable: true);
        }
        if (encoded.length > before) encoded.last['sourceCursor'] = _cursor;
      }
      if (_tableIds.contains(block.id)) continue;
      _add(
        measurer.measure(
          block,
          withIndent:
              options.settings.indent && block.kind == BlockKind.paragraph,
          asChapterTitle: _contentTitle && ordinal == 0,
        ),
      );
    }
    return index < values.length;
  }

  @override
  MeasuredBlock operator [](int index) {
    if (!has(index)) throw RangeError.index(index, values);
    return values[index];
  }
}
