part of 'chapter_layout.dart';

class _LazyMeasuredBlocks implements MeasuredBlockSource {
  _LazyMeasuredBlocks(
    this.chapter,
    this.content,
    this.options,
    BlockMeasurementCache? cache, {
    required this.cacheEnabled,
    required DisplayTree displayTree,
    this.rowBase = 0,
    int startBlock = 0,
    int? endBlock,
    this.includeChapterTitle = true,
  }) : measurementCache = cache,
       _cursor = startBlock,
       _endBlock = endBlock ?? content.blocks.length,
       measurer = BlockMeasurer(
         options,
         styleTable: ChapterStyler.layoutTableOf(content),
         displayTree: displayTree,
         cache: cache,
       ) {
    _tables = {for (final t in content.tables) t.blockIds.first: t};
    _tableIds = content.tables.expand((t) => t.blockIds).toSet();
    _parallel = ParallelFlowLayout(
      content,
      measurer.displayTree!,
      ChapterStyler.layoutTableOf(content),
      options,
    );
    _contentTitle =
        includeChapterTitle &&
        options.insertChapterTitle &&
        ChapterLayout.firstBlockIsChapterTitle(content, chapter.title);
  }
  final Chapter chapter;
  final ChapterContent content;
  final LayoutOptions options;
  final BlockMeasurer measurer;
  final BlockMeasurementCache? measurementCache;
  final bool cacheEnabled;
  final bool includeChapterTitle;
  final int rowBase;
  final values = <MeasuredBlock>[];
  final consumedBefore = <int>[0];
  final measuredById = <String, MeasuredBlock>{};
  final orders = <String, int>{};
  final _encoded = <Map<String, Object?>?>[];
  final _checkpointCursors = <int?>[];
  int encodedThrough = 0;
  bool deferCheckpointEncoding = false;
  int measureUs = 0, encodeUs = 0;
  late final _byId = {for (final b in content.blocks) b.id: b};
  late final Map<String, ContentTable> _tables;
  late final Set<String> _tableIds;
  late final ParallelFlowLayout _parallel;
  late final bool _contentTitle;
  int _cursor;
  final int _endBlock;
  bool _started = false;
  bool _exhausted = false;
  int _requested = -1;
  int get cursor => _cursor;
  bool get needsCachedRows => values.length - _requested <= 3;

  /// 已写进断点的最后一块对应的正文游标。
  ///
  /// 不能直接用 [cursor]：最后量到的那一块还在等下一块决定盒子的下内边距，
  /// 没有交付、也没有写进断点；断点里若记了它，恢复时就会跳过这一块。
  int get checkpointRowCount =>
      _checkpointCursors.lastIndexWhere((cursor) => cursor != null) + 1;

  int checkpointCursorAt(int row) => _checkpointCursors[row]!;

  List<Map<String, Object?>> checkpointRows(int limit) =>
      List.generate(limit, (i) => _encoded[i]!, growable: false);

  bool encodeCheckpointRows(int limit, Stopwatch batch) {
    while (encodedThrough < limit && batch.elapsedMicroseconds < 1500) {
      _encodeNextCheckpointRow();
    }
    return encodedThrough >= limit;
  }

  void _encodeNextCheckpointRow() {
    final watch = readerWorkTraceEnabled ? (Stopwatch()..start()) : null;
    final i = encodedThrough++;
    _encoded[i] ??= {
      ...MeasuredBlockCodec.encode(values[i]),
      'sourceCursor': _checkpointCursors[i],
    };
    if (watch != null) encodeUs += watch.elapsedMicroseconds;
  }

  /// 已经量好、但还不知道「是不是盒子最后一块」的块。
  ///
  /// 盒子的下内边距要看下一块的 boxId 才能决定，所以这里最多缓存一块：
  /// 量到下一块时再把前一块交付出去，保证交付序列与 `ChapterLayout.produce`
  /// 的「整章量完再统一调整」得到完全相同的几何。
  final _pending = <_PendingBlock>[];

  /// 最后一个已交付的块，用来判断当前块是不是盒子的第一块。
  MeasuredBlock? _delivered;

  void _queue(MeasuredBlock block, {required int? sourceCursor}) {
    _pending.add(_PendingBlock(block, sourceCursor));
    _release();
  }

  void _addMeasured(MeasuredBlock block) {
    if (!block.isDecoration || block.isTitleDecoration) {
      measuredById.putIfAbsent(block.blockId, () => block);
      orders.putIfAbsent(block.blockId, () => values.length);
    }
    consumedBefore.add(
      consumedBefore.last +
          (block.isDecoration && !block.isTitleDecoration
              ? 0
              : block.text.length - block.displayPrefixLength + 1),
    );
    values.add(block);
  }

  /// 把能定下来的块交付出去：有下一块，或者正文已经量完。
  void _release() {
    while (_pending.length >= 2 || (_pending.isNotEmpty && _exhausted)) {
      final current = _pending.removeAt(0);
      final next = _pending.isEmpty ? null : _pending.first.block;
      final adjusted = current.block.fitBoxPart(_delivered, next);
      _delivered = adjusted;
      _addMeasured(adjusted);
      if (cacheEnabled) {
        _checkpointCursors.add(current.sourceCursor);
        _encoded.add(null);
        // 远跳先交付页，数值缓存等阅读画面稳定后分批编码。
        if (!deferCheckpointEncoding && encodedThrough == _encoded.length - 1) {
          _encodeNextCheckpointRow();
        }
      }
    }
  }

  /// 量下一块（表格按整块量）。返回是否还有内容可量。
  bool _measureNext() {
    if (!readerWorkTraceEnabled) return _measureNextBlock();
    final watch = Stopwatch()..start();
    final startEncodeUs = encodeUs;
    try {
      return _measureNextBlock();
    } finally {
      measureUs += watch.elapsedMicroseconds - (encodeUs - startEncodeUs);
    }
  }

  bool _measureNextBlock() {
    if (_cursor >= _endBlock) {
      if (!_exhausted) {
        for (final empty in measurer.measureBefore(content.blocks.length)) {
          _queue(empty, sourceCursor: _cursor);
        }
      }
      _exhausted = true;
      _release();
      return false;
    }
    final ordinal = _cursor++;
    final block = content.blocks[ordinal];
    for (final empty in measurer.measureBefore(ordinal)) {
      _queue(empty, sourceCursor: null);
    }
    final table = _tables[block.id];
    if (_parallel.groups.containsKey(ordinal)) {
      final group = _parallel.measure(ordinal, measurer);
      _cursor = _parallel.ends[ordinal]! + 1;
      for (var i = 0; i < group.length; i++) {
        _queue(group[i], sourceCursor: i == group.length - 1 ? _cursor : null);
      }
    } else if (table != null) {
      final group = measureTable(
        table,
        _byId,
        options,
        cache: measurementCache,
        // 增量分页也要按同一份样式表量单元格，否则粗体、颜色和上下标会丢。
        styleTable: ChapterStyler.layoutTableOf(content),
        displayTree: measurer.displayTree,
        order: content.blocks,
      );
      for (var i = 0; i < group.length; i++) {
        // 表格整组按首格的游标续排：只有整组最后一块记游标，恢复时才不会从中间重开表格。
        _queue(group[i], sourceCursor: i == group.length - 1 ? _cursor : null);
      }
    } else if (!_tableIds.contains(block.id)) {
      _queue(
        measurer.measure(
          block,
          withIndent:
              options.settings.indent &&
              (block.kind == BlockKind.paragraph ||
                  block.kind == BlockKind.quote),
          asChapterTitle: _contentTitle && ordinal == 0,
        ),
        sourceCursor: _cursor,
      );
    }
    if (_cursor >= _endBlock) {
      for (final empty in measurer.measureBefore(_endBlock)) {
        _queue(empty, sourceCursor: _cursor);
      }
      _exhausted = true;
    }
    _release();
    return true;
  }

  bool restore(Map<String, dynamic> checkpoint) {
    final cursor = checkpoint['cursor'] as int;
    if (cursor < _cursor ||
        cursor > content.blocks.length ||
        (checkpoint['_from'] as int? ?? 0) != rowBase + values.length) {
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
      _addMeasured(block);
    }
    if (cacheEnabled) {
      final wasEncoded = encodedThrough == _encoded.length;
      _encoded.addAll(raw);
      _checkpointCursors.addAll(raw.map((row) => row['sourceCursor'] as int?));
      if (wasEncoded) encodedThrough = _encoded.length;
    }
    _cursor = cursor;
    _started = true;
    _exhausted = cursor >= content.blocks.length;
    _delivered = values.isEmpty ? null : values.last;
    return true;
  }

  @override
  bool has(int index) {
    if (index > _requested) _requested = index;
    if (!_started) {
      _started = true;
      // PDF的章节只是用于定位的物理页，不把“第N页”插入电子书正文。
      // 章题和短横线只给 TXT 补；其他格式尊重原书，不插入任何标题。
      if (_cursor == 0 &&
          includeChapterTitle &&
          options.insertChapterTitle &&
          content.pdfPage == null &&
          !_contentTitle &&
          chapter.title.trim().isNotEmpty) {
        _queue(measurer.measureChapterTitle(chapter.title), sourceCursor: null);
      }
    }
    while (values.length <= index) {
      if (_exhausted) {
        _release();
        if (values.length <= index) break;
        continue;
      }
      if (!_measureNext()) break;
    }
    return index < values.length;
  }

  @override
  MeasuredBlock operator [](int index) {
    if (!has(index)) throw RangeError.index(index, values);
    return values[index];
  }
}

/// 已测量、等待下一块决定「盒子最后一块」的块。
class _PendingBlock {
  const _PendingBlock(this.block, this.sourceCursor);
  final MeasuredBlock block;

  /// 断点里记录的正文游标；表格整组只有最后一块带游标。
  final int? sourceCursor;
}
