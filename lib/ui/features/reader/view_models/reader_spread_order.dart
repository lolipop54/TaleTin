part of 'reader_session_view_model.dart';

// restart 为内部小节序号，-1 表示以已经独立分页的导入分段起配。
typedef _SpreadUnit = ({int file, String? block, int? restart});
typedef SpreadPages = ({SpreadPageRef left, SpreadPageRef? right});

const _longUnmarkedSource = 64 * 1024;
const _nearbyChapterTail = 8 * 1024;

/// 阅读会话保留跳转的真实页；左右纸面另外计算，章末右侧可以只有背景。
extension ReaderSpreadOrder on ReaderSessionNotifier {
  Future<SpreadPages> pagesAround(SpreadPageRef target) async {
    final session = _scanSession;
    final options = target.layout.options;
    if (_options?.layoutSignature != options.layoutSignature) {
      throw const LayoutCancelled(LayoutCancellationReason.requestSuperseded);
    }
    var order = _spreadOrder;
    if (order == null ||
        order.signature != options.layoutSignature ||
        order.fontRevision != ReadingFonts.environmentRevision ||
        !identical(order.chapters, session.chapters)) {
      order?.flush();
      _spreadOrder = order = _SpreadOrder(this, session, options);
    }
    final release = target.layout.task?.retainForDisplay();
    try {
      final pages = order.previouslyShown(target) ?? await order.around(target);
      order._check();
      return pages;
    } finally {
      release?.call();
    }
  }

  void rememberShownSpread(SpreadPages pages) {
    final order = _spreadOrder;
    if (order == null ||
        order.signature != _options?.layoutSignature ||
        order.fontRevision != ReadingFonts.environmentRevision ||
        !identical(order.chapters, _progressSession?.chapters)) {
      return;
    }
    order.rememberShown(pages);
  }
}

class _SpreadOrder {
  _SpreadOrder(this.reader, ReaderSession session, this.options)
    : book = session.book,
      chapters = session.chapters,
      signature = options.layoutSignature {
    var first = 0, length = 0;
    String? previous;
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      byId[chapter.id] = i;
      final match = session.book.format.isMobi
          ? _mobiPart.firstMatch(chapter.href ?? '')
          : null;
      final source = match?.group(1);
      if (source == null || source != previous || match!.group(2) == '00000') {
        first = i;
        length = 0;
      }
      length += chapter.textLength;
      if (i > first && (i - first >= 3 || length >= _longUnmarkedSource)) {
        _longRoots.add(first);
      }
      roots.add(first);
      ends[first] = i;
      previous = source;
    }
    store = reader._sessionRef.read(layoutCheckpointStoreProvider);
    repository = reader._sessionRef.read(chapterContentRepositoryProvider);
  }

  // 还原 MOBI 导入器生成的连续分段文件的归属，原书章内不因切文件换边。
  static final _mobiPart = RegExp(r'^(.*)-s(\d{5,})\.html$');
  final ReaderSessionNotifier reader;
  final Book book;
  final LayoutOptions options;
  final String signature;
  final fontRevision = ReadingFonts.environmentRevision;
  final List<Chapter> chapters;
  final byId = <String, int>{}, ends = <int, int>{};
  final roots = <int>[];
  final _longRoots = <int>{};
  final _partSizes = <(int, String?), int>{};
  final _indexedStarts = <int, List<SpreadChapterStart>?>{};
  final _lastChapterStarts = <int, String?>{};
  final _sizes = <int, int>{};
  final _after = <int, int>{};
  final _shown = <SpreadPages>[];
  late final LayoutCheckpointStore? store;
  late final ChapterContentRepository repository;
  Future<void>? _loading;
  String? _diskKey;
  Timer? _save;
  bool _dirty = false;

  SpreadPages? previouslyShown(SpreadPageRef target) {
    _shown.removeWhere(
      (pages) => [
        pages.left,
        ?pages.right,
      ].any((page) => page.layout.task?.isDisposed == true),
    );
    return _shown.reversed
        .where(
          (pages) => [pages.left, ?pages.right].any(
            (page) => page.layout.samePageAs(
              target.layout,
              page.pageIndex,
              target.pageIndex,
            ),
          ),
        )
        .firstOrNull;
  }

  void rememberShown(SpreadPages pages) {
    final left = pages.left;
    if (left.layout.options.layoutSignature != signature) return;
    _shown.removeWhere(
      (entry) => entry.left.layout.samePageAs(
        left.layout,
        entry.left.pageIndex,
        left.pageIndex,
      ),
    );
    // 只记实际画过的页，不保活已经离屏的排版任务，也不留截图。
    _shown.add(pages);
    if (_shown.length > 3) _shown.removeAt(0);
  }

  void _check() {
    if (!reader._sessionRef.mounted ||
        !identical(reader._spreadOrder, this) ||
        fontRevision != ReadingFonts.environmentRevision ||
        reader._options?.layoutSignature != signature) {
      throw const LayoutCancelled(LayoutCancellationReason.requestSuperseded);
    }
  }

  Future<void> _read() async {
    final cache = store;
    if (cache == null) return;
    final digest = await repository.spreadSourceDigest(
      reader.bookId,
      chapters.first,
    );
    if (digest == null) return;
    // 同一个 TXT 可能用另一条章名规则重新导入，须同时核对来源、目录和版式。
    final key = await cache.spreadIdentity(
      digest,
      [
        signature,
        book.contentVersion,
        PublicationSectionStore.folder,
        for (final c in chapters) [c.id, c.title, c.textLength],
      ].toString(),
      options.settings.fontFamily,
    );
    if (key == null) return;
    final saved = await cache.readSpreadRuns(reader.bookId, key);
    _check();
    _diskKey = key;
    for (final e in saved.entries) {
      if (ends.containsKey(e.key)) _after.putIfAbsent(e.key, () => e.value);
    }
    if (_dirty) _scheduleSave();
  }

  void _remember(int root, int value) {
    if (_after[root] == value) return;
    _after[root] = value;
    _dirty = true;
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_diskKey != null) {
      _save ??= Timer(const Duration(milliseconds: 400), flush);
    }
  }

  void flush() {
    _save?.cancel();
    _save = null;
    if (_dirty && _diskKey != null) {
      _dirty = false;
      unawaited(
        store!.writeSpreadRuns(reader.bookId, _diskKey!, Map.of(_after)),
      );
    }
  }

  Future<ChapterLayout> _file(int index, {bool end = false}) async {
    _check();
    final live = reader._scanSession;
    for (final cached in [
      live.layout,
      reader._nextChapterLayout,
      reader._previousChapterLayout,
    ]) {
      final ready = reader._matchingChapterLayout(cached, live, index, options);
      if (ready != null &&
          (end
              ? ready.isComplete && !ready.hasLaterWindow
              : ready.firstPage == 0)) {
        return ready;
      }
    }
    return reader._prepareNeighborChapter(
      live,
      index,
      options,
      atEnd: end,
      probe: !end,
    );
  }

  Future<_SpreadUnit> _unit(
    SpreadPageRef p,
    int version,
    Map<int, ChapterLayout> preparedEnds,
  ) async {
    final file = byId[p.layout.chapterId]!;
    final root = roots[file];
    if (!options.spreadDocumentChapters) {
      return (file: root, block: null, restart: null);
    }
    final start = p.layout.spreadSectionAt(p.pageIndex);
    if (start != null) return (file: file, block: start, restart: null);
    final longSource = _longRoots.contains(root);
    final section = p.layout.readsBySection ? p.layout.sectionIndex : null;
    if (section != null &&
        (section > 0 || file == root) &&
        (longSource ||
            chapters[file].textLength >= publicationSectionMinText)) {
      // 此处本来就是独立封页的安全小节。顺翻和远跳均从同一页开始配对。
      return (file: file, block: null, restart: section);
    }
    // 大合集的一个导入分段可有多个真实章首。只有目标位于本段
    // 第一个章首之前时才回查。超长来源最多核对一个紧邻前段。
    final first = longSource && file > root ? file - 1 : root;
    for (var i = file - 1; i >= first; i--) {
      final previous = await _precedingStart(
        i,
        version,
        preparedEnds,
        nearbyOnly: longSource,
      );
      if (previous != null) {
        return (file: i, block: previous, restart: null);
      }
    }
    return longSource
        ? (file: file, block: null, restart: section ?? -1)
        : (file: root, block: null, restart: null);
  }

  Future<String?> _precedingStart(
    int file,
    int version,
    Map<int, ChapterLayout> preparedEnds, {
    required bool nearbyOnly,
  }) async {
    _checkRequest(version);
    final chapter = chapters[file];
    if (!_indexedStarts.containsKey(file) &&
        (nearbyOnly || !_lastChapterStarts.containsKey(file))) {
      final starts = await repository.indexedSpreadStarts(
        reader.bookId,
        chapter,
      );
      _checkRequest(version);
      _indexedStarts[file] = starts;
    }
    final candidates = _indexedStarts[file];
    final earliest = chapter.textLength - _nearbyChapterTail;
    if (candidates != null &&
        (candidates.isEmpty ||
            (nearbyOnly && candidates.last.textOffset < earliest))) {
      return null;
    }
    if (!_lastChapterStarts.containsKey(file)) {
      // 需要实际排版的只有最近候选段。作者隐藏的章题按实际可见块定位。
      // 紧邻的续段需要它的尾页来数页，从尾页核实可省掉先准备首页的往返。
      final atEnd = nearbyOnly && candidates != null;
      if (atEnd) {
        final block = candidates.last.blockId;
        final source = await repository.chapterSectionsForLayout(
          reader.bookId,
          chapter,
          book.format,
        );
        _checkRequest(version);
        if (source?.lastChapterStart == block) {
          final count = await reader._sessionRef
              .read(readerEngineProvider)
              .verifiedChapterTail(
                LayoutRequest.sections(
                  book: book,
                  bookId: reader.bookId,
                  contentVersion: book.contentVersion,
                  chapter: chapter,
                  source: source!,
                  options: options,
                ),
                block,
                token: reader._token,
              );
          _checkRequest(version);
          if (count != null) {
            _partSizes[(file, block)] = count;
            return _lastChapterStarts[file] = block;
          }
        }
      }
      final layout = await _file(file, end: atEnd);
      _checkRequest(version);
      if (atEnd) preparedEnds[file] = layout;
      _lastChapterStarts[file] = layout.lastDeclaredSpreadStart;
    }
    final start = _lastChapterStarts[file];
    if (nearbyOnly && start != null && candidates != null) {
      for (final candidate in candidates.reversed) {
        if (candidate.blockId == start) {
          return candidate.textOffset >= earliest ? start : null;
        }
      }
    }
    return start;
  }

  void _checkRequest(int version) {
    _check();
    if (version != reader._tokenVersion) {
      throw const LayoutCancelled(LayoutCancellationReason.requestSuperseded);
    }
  }

  Future<int> _offset(
    SpreadPageRef p,
    _SpreadUnit unit,
    int version,
    Map<int, ChapterLayout> preparedEnds,
  ) async {
    if (unit.restart case final section?) {
      return section < 0 ? p.pageIndex : p.pageIndex - p.layout.firstPage;
    }
    final file = byId[p.layout.chapterId]!;
    var offset = await p.layout.pageOffsetFrom(
      p.pageIndex,
      file == unit.file ? unit.block : null,
      token: reader._token?.isCancelled == false ? reader._token : null,
    );
    if (file == unit.file) {
      return offset;
    }
    final counts = reader._sessionRef.read(readerPageCountsProvider);
    // 仅需完整段的页数时直接使用同版式页数索引。起点在段中间时仍计算准确尾部。
    late final countSession = counts?.session(book, options);
    for (var i = unit.file; i < file; i++) {
      _checkRequest(version);
      final start = i == unit.file ? unit.block : null;
      final part = (i, start);
      var count = _partSizes[part];
      if (count == null && start == null && counts != null) {
        try {
          count = await (await countSession)?.chapterTotal(i);
        } on Object {
          // 页数缓存可重建，按原精度完成缺失的排版。
        }
        _checkRequest(version);
      }
      if (count == null) {
        final last = preparedEnds.remove(i) ?? await _file(i, end: true);
        count = last.isEmpty
            ? 0
            : 1 +
                  await last.pageOffsetFrom(
                    last.pageCount - 1,
                    start,
                    token: reader._token,
                  );
      }
      _partSizes[part] = count;
      offset += count;
    }
    return offset;
  }

  // 只有独立的未标章单页才参与原有的单页拼组。第一页已确认是章首，
  // 或看到了第二页，都可以结束探测。
  Future<int> _sizeClass(int root, int version) async {
    if (options.spreadDocumentChapters && _longRoots.contains(root)) return 2;
    final known = _sizes[root];
    if (known != null) return known;
    var count = 0;
    for (var i = root; i <= ends[root]!; i++) {
      _checkRequest(version);
      final layout = await _file(i);
      final release = layout.task?.retainForDisplay();
      try {
        if (layout.spreadStarts.isNotEmpty) return _sizes[root] = 2;
        if (layout.pages.isEmpty) continue;
        if (++count == 2) return _sizes[root] = 2;
        final next = await layout.adjacentPage(
          layout.firstPage,
          forward: true,
          lookAhead: 0,
        );
        if (next != null) return _sizes[root] = 2;
      } finally {
        release?.call();
      }
    }
    return _sizes[root] = count;
  }

  Future<int> _slot(int target, int version) async {
    // 只有首次遇到单页组才读磁盘。无法确认旧版式时照常从当前分页判定。
    final loading = _loading ??= _read().catchError((Object _) {});
    // 从书头或已知前章进入时，首屏无需等待确认磁盘字体和目录摘要。
    if (target > 0 && !_after.containsKey(roots[target - 1])) {
      await loading;
    }
    _checkRequest(version);
    final known = _after[target];
    if (known != null && known > 0) return known;
    final pending = <(int, int)>[];
    var slot = 0;
    for (var before = target - 1; before >= 0;) {
      final root = roots[before];
      final cached = _after[root];
      if (cached != null) {
        slot = cached;
        break;
      }
      final singles = await _sizeClass(root, version);
      if (singles >= 2) break;
      pending.add((root, singles));
      before = root - 1;
    }
    _checkRequest(version);
    int advance(int current, int n) =>
        n == 0 ? current : (current + n - 1) % 32 + 1;
    for (final (file, singles) in pending.reversed) {
      slot = advance(slot, singles);
      _remember(file, slot);
    }
    slot = advance(slot, 1);
    _remember(target, slot);
    return slot;
  }

  Future<SpreadPages> around(SpreadPageRef target) async {
    final version = reader._tokenVersion;
    final file = byId[target.layout.chapterId]!;
    _lastChapterStarts[file] = target.layout.lastDeclaredSpreadStart;
    final preparedEnds = <int, ChapterLayout>{};
    final unit = await _unit(target, version, preparedEnds);
    _checkRequest(version);
    final offset = await _offset(target, unit, version, preparedEnds);
    _checkRequest(version);
    if (offset.isOdd) {
      final left = await reader.adjacentSpreadPage(target, false);
      _checkRequest(version);
      return (left: left!, right: target);
    }
    if (unit.restart != null &&
        target.layout.isComplete &&
        target.pageIndex + 1 == target.layout.pageCount) {
      return (left: target, right: null);
    }
    var right = await target.layout.adjacentPage(
      target.pageIndex,
      forward: true,
      lookAhead: 0,
    );
    if (right == null && file < ends[roots[file]]!) {
      right = await reader.adjacentSpreadPage(target, true);
    }
    _checkRequest(version);
    if (right != null && await _unit(right, version, preparedEnds) == unit) {
      if (unit.block == null) _sizes[unit.file] = 2;
      return (left: target, right: right);
    }
    if (unit.block != null ||
        unit.restart != null ||
        offset > 0 ||
        await _sizeClass(unit.file, version) != 1) {
      return (left: target, right: null);
    }
    final slot = await _slot(unit.file, version);
    if (slot.isEven) {
      final left = await reader.adjacentSpreadPage(target, false);
      _checkRequest(version);
      return (left: left!, right: target);
    }
    right ??= await reader.adjacentSpreadPage(target, true);
    if (right != null) {
      final release = right.layout.task?.retainForDisplay();
      try {
        final rightRoot = roots[byId[right.layout.chapterId]!];
        if (await _sizeClass(rightRoot, version) == 1) {
          return (left: target, right: right);
        }
      } finally {
        release?.call();
      }
    }
    return (left: target, right: null);
  }
}
