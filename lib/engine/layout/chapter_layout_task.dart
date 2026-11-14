part of 'chapter_layout.dart';

typedef _TxtPageWindowState = ({
  _LazyMeasuredBlocks source,
  Iterator<PageSlice?> steps,
  List<PageSlice> pages,
  bool complete,
  ChapterLayout? snapshot,
});

/// 同参数只有一个迭代器。目标请求可取消，但不会销毁其他消费者需要的页面。
class ChapterLayoutTask {
  ChapterLayoutTask({
    required this.bookId,
    required this.contentVersion,
    required this.chapter,
    required ChapterContent? content,
    required this.options,
    this._indexedTxt,
    this.measurementCache,
    this.onCheckpoint,
    this.readCheckpoint,
    this.readPageWindow,
  }) : _wholeContent = content == null
           ? null
           : CssLayoutStyles.resolve(content, options) {
    final whole = _wholeContent;
    _wholeDisplayTree = whole == null ? null : DisplayTree.build(whole);
    _txtWindows = whole != null && usesTxtWindows(chapter, whole, options)
        ? TxtChapterSections(whole.blocks.map((block) => block.textLength))
        : null;
    if (whole != null) {
      _source = _newSource();
      _steps = _paginate(_source);
      _windowReady = true;
    }
    _mapper = LocatorMapper(
      bookId: bookId,
      contentVersion: contentVersion,
      chapterId: chapter.id,
    );
    _totalLength = whole == null
        ? chapter.textLength
        : _txtWindows?.textLength ?? _mapper.totalLength(whole.blocks);
  }

  static bool usesTxtWindows(
    Chapter chapter,
    ChapterContent content,
    LayoutOptions options,
  ) =>
      options.insertChapterTitle &&
      chapter.textLength >= kLongTxtChapterLength &&
      content.blocks.length > 1 &&
      content.displaySourceJson == null &&
      content.tables.isEmpty;

  final String bookId;
  final int contentVersion;
  final Chapter chapter;
  final ChapterContent? _wholeContent;
  ChapterContent get content => _wholeContent ?? _source.content;
  final LayoutOptions options;
  final BlockMeasurementCache? measurementCache;
  final void Function(Map<String, Object?>)? onCheckpoint;
  final Future<Map<String, dynamic>?> Function(
    int? throughCursor,
    int afterBlocks,
  )?
  readCheckpoint;
  final Future<Map<String, dynamic>?> Function(PageCheckpointTarget, int?)?
  readPageWindow;
  late final DisplayTree? _wholeDisplayTree;
  DisplayTree get _displayTree =>
      _wholeDisplayTree ?? _source.measurer.displayTree!;
  late _LazyMeasuredBlocks _source;
  late Iterator<PageSlice?> _steps;
  late final LocatorMapper _mapper;
  late final int _totalLength;
  late final TxtChapterSections? _txtWindows;
  final TxtChapterSource? _indexedTxt;
  bool _windowReady = false;
  int _txtWindow = 0;
  int get _txtWindowCount =>
      _indexedTxt?.starts.length ?? _txtWindows?.starts.length ?? 0;
  int get _txtOffset =>
      _indexedTxt?.starts[_txtWindow].textOffset ??
      _txtWindows?.starts[_txtWindow].offset ??
      0;
  var _pages = <PageSlice>[];
  final _recentTxtWindows = <int, _TxtPageWindowState>{};
  final _pageRestarts = <List<int>>[];
  List<int>? _restart;
  // 长 TXT 的页序只在一个窗口内连续。窗口用起始文字位置区分，
  // 跨窗口翻页由 adjacentPage 交接，进度始终按真实文字位置计算。
  int get _firstPage => _restart?[0] ?? _txtOffset;
  int get _pageCount => _firstPage + _pages.length;
  final _events = StreamController<ChapterLayout>.broadcast(sync: true);
  Future<void> _flight = Future.value();
  bool _complete = false, _background = false, _wantBackground = false;
  LayoutCancellationReason? _disposalReason;
  bool get isDisposed => _disposalReason != null;
  Object? _failure;
  int _foreground = 0;
  int _visibleUsers = 0;
  int _savedPages = 0;
  int _checkpointLimit = 0;
  Timer? _timer;
  Completer<void>? _wake;
  ChapterLayout? _snapshot;
  Stream<ChapterLayout> get updates => _events.stream;
  bool get isInUse => _foreground > 0 || _wantBackground || _visibleUsers > 0;

  /// 已交付的页面还需要用这份任务查找相邻页，即使此时没有后台补排。
  VoidCallback retainForDisplay() {
    _visibleUsers++;
    return () => _visibleUsers--;
  }

  void _checkActive([LayoutToken? token]) {
    if (_disposalReason case final reason?) throw LayoutCancelled(reason);
    if (token?.isCancelled ?? false) throw const LayoutCancelled();
  }

  int _maxStepUs = 0;
  int _stepUs = 0;
  late bool _cacheMore = _txtWindowCount == 0;

  _LazyMeasuredBlocks _newSource([int rowBase = 0, ChapterContent? section]) {
    final body = section ?? _wholeContent!;
    return _LazyMeasuredBlocks(
      chapter,
      body,
      options,
      measurementCache,
      cacheEnabled: onCheckpoint != null,
      displayTree: _wholeDisplayTree ?? DisplayTree.build(body),
      rowBase: rowBase,
      startBlock: _txtWindows?.starts[_txtWindow].paragraph ?? 0,
      endBlock: _txtWindowEnd,
      includeChapterTitle: _indexedTxt == null || _txtWindow == 0,
    );
  }

  int? get _txtWindowEnd {
    final windows = _txtWindows;
    if (windows == null) return null;
    final next = _txtWindow + 1;
    return next < windows.starts.length
        ? windows.starts[next].paragraph
        : windows.paragraphCount;
  }

  Iterator<PageSlice?> _paginate(
    _LazyMeasuredBlocks source, [
    List<int>? restart,
  ]) =>
      ChapterPaginator(
            pageHeight: options.contentHeight,
            gapBefore: source.measurer.gapBefore,
          )
          .steps(
            source,
            firstPage: _firstPage,
            firstBlock: restart == null ? 0 : 1,
            firstLine: restart?[2] ?? 0,
            onBoundary: onCheckpoint != null || readPageWindow != null
                ? _recordBoundary
                : null,
          )
          .iterator;

  void _recordBoundary(int page, int row, int line) {
    if (row < 1 || page - (_pageRestarts.lastOrNull?[0] ?? 0) < 24) return;
    final block = _source.values[row];
    final ordinal = _displayTree.blockIndexById[block.blockId];
    if (ordinal == null || block.isDecoration || block.tableId != null) return;
    final offset = block.lines.isEmpty
        ? 0
        : (block.lines[line].start - block.displayPrefixLength).clamp(
            0,
            block.text.length,
          );
    _pageRestarts.add([
      page,
      _source.rowBase + row,
      line,
      ordinal,
      offset,
      (_restart?[5] ?? 0) + _source.consumedBefore[row - 1],
    ]);
  }

  void _replaceWindow(
    _LazyMeasuredBlocks source,
    List<int>? restart, {
    bool cacheMore = true,
  }) {
    _source = source;
    _restart = restart;
    _steps = _paginate(source, restart);
    _pages.clear();
    _pageRestarts.clear();
    if (restart != null) _pageRestarts.add(restart);
    _complete = false;
    _snapshot = null;
    _cacheMore = cacheMore;
    _savedPages = _checkpointLimit = 0;
  }

  Future<void> _selectTxtWindow(int window, LayoutToken? token) async {
    if (_windowReady && _txtWindow == window) return;
    final cached = _recentTxtWindows[window];
    final section = cached == null
        ? await _indexedTxt?.readSection(window)
        : null;
    _checkActive(token);
    if (_windowReady && _pages.isNotEmpty) {
      _recentTxtWindows[_txtWindow] = (
        source: _source,
        steps: _steps,
        pages: _pages,
        complete: _complete,
        snapshot: _snapshot,
      );
    }
    _txtWindow = window;
    _windowReady = true;
    _recentTxtWindows.remove(window);
    while (_recentTxtWindows.length > 2) {
      _recentTxtWindows.remove(_recentTxtWindows.keys.first);
    }
    if (cached != null) {
      _source = cached.source;
      _steps = cached.steps;
      _pages = cached.pages;
      _complete = cached.complete;
      _snapshot = cached.snapshot;
    } else {
      _pages = [];
      _replaceWindow(_newSource(0, section), null, cacheMore: false);
    }
  }

  Future<bool> _tryPageRestart(
    PageCheckpointTarget target,
    int? through,
    LayoutToken? token, {
    required bool earlier,
  }) async {
    final read = readPageWindow;
    if (read == null) return false;
    final data = await read(target, through);
    _checkActive(token);
    if (data == null) return false;
    try {
      final point = (data['_pageRestart'] as List).cast<int>();
      if (point.length != 6 ||
          (!earlier && point[0] < _pageCount) ||
          point[3] >= content.blocks.length) {
        return false;
      }
      final source = _newSource(point[1] - 1);
      if (!source.restore(data) || source.values.length < 2) return false;
      final first = source.values[1];
      if (first.blockId != content.blocks[point[3]].id ||
          first.isDecoration ||
          first.tableId != null ||
          point[2] >= (first.lines.isEmpty ? 1 : first.lines.length)) {
        return false;
      }
      _replaceWindow(source, point, cacheMore: data['_hasMore'] == true);
      return true;
    } on Object {
      // 缓存异常回到常规排版，已交付页面仍持有原快照。
      return false;
    }
  }

  Future<void> _restoreTo(int? cursor) async {
    if (readCheckpoint == null ||
        !_cacheMore ||
        (cursor != null && cursor <= _source.cursor)) {
      return;
    }
    final data = await readCheckpoint!(
      cursor,
      _source.rowBase + _source.values.length,
    );
    _checkActive();
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
    if (onCheckpoint == null) return;
    final limit = _source.checkpointRowCount;
    if (limit == 0) return;
    _savedPages = _pages.length;
    if (_source.encodedThrough < limit) {
      _checkpointLimit = limit;
      return;
    }
    _publishCheckpoint(limit);
  }

  void _publishCheckpoint(int limit) {
    _checkpointLimit = 0;
    onCheckpoint!({
      // 用「已交付」的游标：等待下一块的 pending 块不能算进断点。
      'cursor': _source.checkpointCursorAt(limit - 1),
      if (_source.rowBase != 0) '_from': _source.rowBase,
      'blocks': _source.checkpointRows(limit),
      if (_pageRestarts.isNotEmpty)
        'pageRestarts': [
          for (final point in _pageRestarts)
            if (point[1] < _source.rowBase + limit) point,
        ],
    });
  }

  ChapterLayout get snapshot => _snapshot ??= _view(copy: true);

  /// 交给界面的快照冻结列表；同步查目标时直接读任务自己的追加列表。
  /// 内部视图不能交付或跨 await 持有，否则旧画面会看见后续追加的页面。
  ChapterLayout _view({required bool copy}) => ChapterLayout._(
    bookId: bookId,
    contentVersion: contentVersion,
    chapterId: chapter.id,
    chapterTitle: chapter.title,
    blocks: copy ? List.unmodifiable(_source.values) : _source.values,
    pages: copy ? List.unmodifiable(_pages) : _pages,
    mapper: _mapper,
    totalLength: _totalLength,
    content: content,
    options: options,
    task: this,
    isComplete: _complete,
    firstPage: _firstPage,
    consumedBeforeWindow: _restart?[5] ?? _txtOffset,
    txtWindow: _txtWindowCount == 0 ? null : _txtWindow,
    // 只追加索引，不修改既有页或块顺序。旧快照未覆盖的目标仍返回 null。
    measuredById: _source.measuredById,
    blockOrders: _source.orders,
    // 和块索引一样只追加；恢复更早窗口时旧快照仍持有原来的累计表。
    consumedBefore: _source.consumedBefore,
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
    _checkActive();
    if (_failure != null) throw _failure!;
    if (_complete) return false;
    final watch = readerWorkTraceEnabled ? (Stopwatch()..start()) : null;
    final moved = _steps.moveNext();
    if (watch != null) {
      final elapsed = watch.elapsedMicroseconds;
      _stepUs += elapsed;
      if (elapsed > _maxStepUs) _maxStepUs = elapsed;
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

  /// 请求目标页及指定数量的后页。前页已在确定的前缀里；章末须推进至 EOF。
  Future<ChapterLayout> ensure({
    Locator? target,
    int? chapterOffset,
    int? page,
    bool atEnd = false,
    LayoutToken? token,
    int lookAhead = 4,
    int foregroundBudgetUs = 2000,
    bool deferCheckpointEncoding = false,
    bool allowPageRestart = false,
    int? txtWindow,
  }) async {
    _foreground++;
    try {
      return await _serial(() async {
        _checkActive(token);
        await EnglishHyphenation.prepare();
        if (_txtWindowCount > 0) {
          final indexed = _indexedTxt;
          final paragraph = target == null
              ? 0
              : (indexed == null
                        ? _displayTree.blockIndexById[target.blockId]
                        : TxtChapterSource.paragraphOf(target.blockId)) ??
                    0;
          final window =
              txtWindow ??
              (atEnd
                  ? _txtWindowCount - 1
                  : indexed == null
                  ? _txtWindows!.containingParagraph(paragraph)
                  : chapterOffset == null
                  ? indexed.forParagraph(paragraph)
                  : indexed.forOffset(chapterOffset));
          await _selectTxtWindow(window, token);
        }
        final anchor = chapterOffset == null
            ? target
            : _view(copy: false).txtLocatorAtOffset(chapterOffset);
        final targetBlock = anchor == null
            ? null
            : _displayTree.blockIndexById[anchor.blockId];
        await _source.measurer.prepareMath(content);
        final restart = _restart;
        final earlier =
            restart != null &&
            (anchor == null
                ? !atEnd && (page ?? 0) < _firstPage
                : targetBlock == null ||
                      targetBlock < restart[3] ||
                      targetBlock == restart[3] &&
                          anchor.utf16Offset <= restart[4]);
        var resumed = false;
        if (earlier ||
            (allowPageRestart &&
                targetBlock != null &&
                _view(copy: false)._pageIndexOf(anchor!) == null)) {
          resumed = await _tryPageRestart(
            (
              block: targetBlock,
              offset: anchor?.utf16Offset ?? 0,
              page: anchor == null ? page ?? 0 : null,
            ),
            targetBlock == null ? null : targetBlock + 1,
            token,
            earlier: earlier,
          );
          if (earlier && !resumed) _replaceWindow(_newSource(), null);
        }
        if (atEnd) {
          await _restoreTo(null);
        } else if (targetBlock != null) {
          await _restoreTo(targetBlock + 1);
        } else if (_pageCount <= (page ?? 0)) {
          await _restoreTo(_source.cursor + 1);
        }
        final trace = ReaderWorkTrace.start('layout.window', {
          'chapter': chapter.ordinal,
          'blocks': content.blocks.length,
          'atEnd': atEnd,
          'checkpointPage': resumed ? _firstPage : null,
          if (_txtWindowCount > 0) 'txtWindow': _txtWindow,
          'preparedPages': _pages.length,
        });
        final batch = Stopwatch()..start();
        final startStepUs = _stepUs;
        final startMeasureUs = _source.measureUs;
        final startEncodeUs = _source.encodeUs;
        _source.deferCheckpointEncoding = deferCheckpointEncoding;
        int? targetPage;
        var searchedPages = 0;
        try {
          while (true) {
            _checkActive(token);
            if (anchor != null &&
                targetPage == null &&
                (_pages.length > searchedPages || _complete)) {
              // 封口页不再变化，已经查过且没有目标的页无需反复扫描。
              // 不为每个测量步骤复制全部块/页；长章冷跳转保持线性推进。
              targetPage = _view(copy: false)
                  ._pageIndexOf(anchor, fromPage: searchedPages);
              searchedPages = _pages.length;
            }
            final index = anchor == null ? page ?? _firstPage : targetPage;
            if (_complete ||
                (!atEnd && index != null && _pageCount > index + lookAhead)) {
              break;
            }
            // 已确认磁盘没有后续分段时，纯计算步骤无需反复挂起再恢复。
            if (_cacheMore &&
                readCheckpoint != null &&
                _source.needsCachedRows) {
              await _restoreTo(_source.cursor + 1);
            }
            _step();
            if (batch.elapsedMicroseconds >= foregroundBudgetUs) {
              await Future<void>.delayed(Duration.zero);
              batch.reset();
            }
          }
          trace?.details.addAll({
            'pages': _pageCount,
            'complete': _complete,
            'measuredBlocks': _source.values.length,
            'maxStepUs': _maxStepUs,
            'measureUs': _source.measureUs - startMeasureUs,
            'checkpointEncodeUs': _source.encodeUs - startEncodeUs,
            'stepUs': _stepUs - startStepUs,
          });
          if (_complete || _pages.length - _savedPages >= 48) _saveCheckpoint();
          return snapshot;
        } finally {
          _source.deferCheckpointEncoding = false;
          trace?.finish();
        }
      });
    } finally {
      _foreground--;
    }
  }

  void resumeBackground() {
    _wantBackground = true;
    if (_background || (_complete && _checkpointLimit == 0) || isDisposed) {
      return;
    }
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
    var source = _source;
    try {
      while (_wantBackground &&
          (!_complete || _checkpointLimit != 0) &&
          !isDisposed) {
        final wake = _wake = Completer<void>();
        _timer = Timer(const Duration(milliseconds: 8), () {
          if (!wake.isCompleted) wake.complete();
        });
        await wake.future;
        if (!_wantBackground || isDisposed) break;
        if (LayoutWorkGate.blocked || _foreground > 0) continue;
        if (!identical(source, _source)) {
          source = _source;
          published = saved = _pages.length;
        }
        final wasComplete = _complete;
        await _serial(() async {
          final batch = Stopwatch()..start();
          if (_checkpointLimit != 0 &&
              _wantBackground &&
              !isDisposed &&
              !LayoutWorkGate.blocked &&
              _foreground == 0 &&
              _source.encodeCheckpointRows(_checkpointLimit, batch)) {
            _publishCheckpoint(_checkpointLimit);
          }
          while (_wantBackground &&
              !_complete &&
              !isDisposed &&
              !LayoutWorkGate.blocked &&
              _foreground == 0 &&
              batch.elapsedMicroseconds < 1500) {
            if (_cacheMore &&
                readCheckpoint != null &&
                _source.needsCachedRows) {
              await _restoreTo(_source.cursor + 1);
            }
            if (LayoutWorkGate.blocked || _foreground > 0 || !_wantBackground) {
              break;
            }
            _step();
            if (batch.elapsedMicroseconds >= 1500) break;
          }
        });
        if (!isDisposed &&
            ((!wasComplete && _complete) || _pages.length - published >= 12)) {
          published = _pages.length;
          if (_events.hasListener) _events.add(snapshot);
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
      if (_wantBackground && !isDisposed && _failure == null) {
        resumeBackground();
      }
    }
  }

  void dispose({
    LayoutCancellationReason reason = LayoutCancellationReason.taskDisposed,
  }) {
    if (isDisposed) return;
    _disposalReason = reason;
    pauseBackground();
    unawaited(_events.close());
  }
}
