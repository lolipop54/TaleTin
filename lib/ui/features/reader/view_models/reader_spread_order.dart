part of 'reader_session_view_model.dart';

typedef _SpreadUnit = ({int file, String? block});
typedef SpreadPages = ({SpreadPageRef left, SpreadPageRef? right});

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
        !identical(order.chapters, session.chapters)) {
      order?.flush();
      _spreadOrder = order = _SpreadOrder(this, session, options);
    }
    final release = target.layout.task?.retainForDisplay();
    try {
      final pages = await order.around(target);
      order._check();
      return pages;
    } finally {
      release?.call();
    }
  }
}

class _SpreadOrder {
  _SpreadOrder(this.reader, ReaderSession session, this.options)
    : book = session.book,
      chapters = session.chapters,
      signature = options.layoutSignature {
    var first = 0;
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
  final List<Chapter> chapters;
  final byId = <String, int>{}, ends = <int, int>{};
  final roots = <int>[];
  final _partSizes = <int, int>{};
  final _sectionsByFile = <int, List<String?>>{};
  final _sizes = <_SpreadUnit, int>{};
  final _after = <int, int>{};
  late final LayoutCheckpointStore? store;
  late final ChapterContentRepository repository;
  Future<void>? _loading;
  String? _diskKey;
  Timer? _save;
  bool _dirty = false;

  void _check() {
    if (!reader._sessionRef.mounted ||
        !identical(reader._spreadOrder, this) ||
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
              ? ready.isComplete && !ready.hasLaterTxtWindow
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

  _SpreadUnit _unit(SpreadPageRef p) => (
    file: roots[byId[p.layout.chapterId]!],
    block: p.layout.spreadSectionAt(p.pageIndex),
  );

  Future<int> _offset(SpreadPageRef p, _SpreadUnit unit) async {
    final version = reader._tokenVersion;
    final file = byId[p.layout.chapterId]!;
    var offset =
        await p.layout.physicalPageNumber(
          p.pageIndex,
          token: reader._token?.isCancelled == false ? reader._token : null,
        ) -
        await p.layout.sectionStartPage(unit.block);
    for (var i = unit.file; i < file; i++) {
      if (version != reader._tokenVersion) {
        throw const LayoutCancelled(LayoutCancellationReason.requestSuperseded);
      }
      var count = _partSizes[i];
      if (count == null) {
        final last = await _file(i, end: true);
        count = _partSizes[i] = last.pageCount;
      }
      offset += count;
    }
    return offset;
  }

  // 确认有第二页就能终止单页章计数，无需为了判定前一章而排到章末。
  Future<int> _sizeClass(_SpreadUnit unit) async {
    final known = _sizes[unit];
    if (known != null) return known;
    var count = 0;
    for (var i = unit.file; i <= ends[unit.file]!; i++) {
      final layout = await _file(i);
      final release = layout.task?.retainForDisplay();
      try {
        if (layout.pages.isEmpty) continue;
        final start = await layout.sectionStartPage(unit.block);
        final prepared = layout.page(start) != null
            ? layout
            : await layout.ensurePage(start);
        if (++count == 2) return _sizes[unit] = 2;
        final next = await prepared.adjacentPage(
          start,
          forward: true,
          lookAhead: 0,
        );
        if (next != null && _unit(next) == unit) return _sizes[unit] = 2;
        if (next != null) break;
      } finally {
        release?.call();
      }
    }
    return _sizes[unit] = count;
  }

  Future<List<String?>> _sections(int root) async {
    if (book.format != BookFormat.epub) return const [null];
    final known = _sectionsByFile[root];
    if (known != null) return known;
    final layout = await _file(root);
    return _sectionsByFile[root] = [null, ...layout.spreadStarts];
  }

  Future<int> _slot(_SpreadUnit target) async {
    final version = reader._tokenVersion;
    // 只有首次遇到单页组才读磁盘。无法确认旧版式时照常从当前分页判定。
    final loading = _loading ??= _read().catchError((Object _) {});
    // 从书头或已知前章进入时，首屏无需等待确认磁盘字体和目录摘要。
    if (target.file > 0 && !_after.containsKey(roots[target.file - 1])) {
      await loading;
    }
    _check();
    final known = _after[target.file];
    if (known != null &&
        known > 0 &&
        (await _sections(target.file)).last == target.block) {
      return known;
    }
    final pending = <(int, int)>[];
    var root = target.file;
    var preceding = 0;
    var slot = 0;
    while (root >= 0) {
      final cached = _after[root];
      if (root != target.file && cached != null) {
        slot = cached;
        break;
      }
      final sections = await _sections(root);
      final limit = root == target.file
          ? sections.indexOf(target.block)
          : sections.length;
      var singles = 0;
      var stopped = false;
      for (var i = limit - 1; i >= 0; i--) {
        if (version != reader._tokenVersion) {
          throw const LayoutCancelled(
            LayoutCancellationReason.requestSuperseded,
          );
        }
        final size = await _sizeClass((file: root, block: sections[i]));
        if (size >= 2) {
          stopped = true;
          break;
        }
        singles += size;
      }
      if (root == target.file) {
        preceding = singles;
      } else {
        pending.add((root, singles));
      }
      if (stopped || root == 0) break;
      root = roots[root - 1];
    }
    int advance(int current, int n) =>
        n == 0 ? current : (current + n - 1) % 32 + 1;
    for (final (file, singles) in pending.reversed) {
      slot = advance(slot, singles);
      _remember(file, slot);
    }
    slot = advance(slot, preceding + 1);
    if ((await _sections(target.file)).last == target.block) {
      _remember(target.file, slot);
    }
    return slot;
  }

  Future<SpreadPages> around(SpreadPageRef target) async {
    final unit = _unit(target);
    if (book.format == BookFormat.epub) {
      _sectionsByFile.putIfAbsent(
        unit.file,
        () => [null, ...target.layout.spreadStarts],
      );
    }
    final offset = await _offset(target, unit);
    _check();
    if (offset.isOdd) {
      final left = await reader.adjacentSpreadPage(target, false);
      return (left: left!, right: target);
    }
    var right = await target.layout.adjacentPage(
      target.pageIndex,
      forward: true,
    );
    if (right == null && byId[target.layout.chapterId]! < ends[unit.file]!) {
      right = await reader.adjacentSpreadPage(target, true);
    }
    if (right != null && _unit(right) == unit) {
      _sizes[unit] = 2;
      return (left: target, right: right);
    }
    if (offset > 0) return (left: target, right: null);
    _sizes[unit] = 1;
    final slot = await _slot(unit);
    if (slot.isEven) {
      final left = await reader.adjacentSpreadPage(target, false);
      return (left: left!, right: target);
    }
    right ??= await reader.adjacentSpreadPage(target, true);
    if (right != null) {
      final release = right.layout.task?.retainForDisplay();
      try {
        if (await _sizeClass(_unit(right)) == 1) {
          return (left: target, right: right);
        }
      } finally {
        release?.call();
      }
    }
    return (left: target, right: null);
  }
}
