part of 'original_scroll_area.dart';

mixin _OriginalScrollSelection on ConsumerState<OriginalScrollArea> {
  InAppWebViewController? get host;
  Map<int, ({ChapterContent content, LocatorDomMap map})> get _maps;
  Future<void> _stopNativeScroll();
  int get _request;
  Future<Object?> _message(Map<String, dynamic> raw);
  final _selectionKey = GlobalKey<ScrollSelectionLayerState>();
  final _selectionMotion = ValueNotifier(0);
  late ScrollSelectionBackend _selectionBackend;
  List<ScrollDecoration> _storedDecorations = const [];

  Future<Object?> _selectionCommand(String source) async {
    final raw = await host?.evaluateJavascript(source: 'JSON.stringify(window.gtScroll ? $source : null)');
    return raw is String ? jsonDecode(raw) : null;
  }
  OriginalSelectionMap? _selectionMap(int index) {
    final entry = _maps[index];
    return entry == null ? null : OriginalSelectionMap(map: entry.map, content: entry.content);
  }
  List<Map<String, Object?>> _segments(SelectionRange range) {
    final ordered = normalizeRange(range, chapterOrdinals: chapterOrdinalsOf(widget.session.chapters));
    final from = widget.session.chapters.indexWhere((c) => c.id == ordered.start.chapterId);
    final to = widget.session.chapters.indexWhere((c) => c.id == ordered.end.chapterId);
    final result = <Map<String, Object?>>[];
    for (final index in _maps.keys.toList()..sort()) {
      if (index < from || index > to) continue;
      final map = _selectionMap(index)!;
      final start = index == from ? map.pointOf(ordered.start) : map.chapterEdgePoint(atEnd: false);
      final end = index == to ? map.pointOf(ordered.end, end: true) : map.chapterEdgePoint(atEnd: true);
      if (start != null && end != null) {
        result.add({'index': index, 'from': start, 'to': end, 'start': index == from, 'end': index == to});
      }
    }
    return result;
  }
  Future<List<ScrollRangeGeometry>> _measureRanges(List<SelectionRange> ranges) async {
    final raw = await _selectionCommand('gtScroll.measureRanges(${jsonEncode(ranges.map(_segments).toList())})');
    if (raw is! List) return [for (final _ in ranges) const ScrollRangeGeometry([])];
    Offset? point(Object? value) => value is Map
      ? Offset((value['x'] as num).toDouble(), (value['y'] as num).toDouble()) : null;
    double height(Object? value) => value is Map ? (value['height'] as num).toDouble() : 0;
    bool reversed(int i) => compareLocators(ranges[i].start, ranges[i].end,
      chapterOrdinals: chapterOrdinalsOf(widget.session.chapters)) > 0;
    return [for (var i = 0; i < raw.length; i++)
      ScrollRangeGeometry([for (final r in raw[i]['rects'] as List)
        Rect.fromLTRB((r['left'] as num).toDouble(), (r['top'] as num).toDouble(),
          (r['right'] as num).toDouble(), (r['bottom'] as num).toDouble())],
        start: point(raw[i][reversed(i) ? 'end' : 'start']),
        end: point(raw[i][reversed(i) ? 'start' : 'end']),
        startHeight: height(raw[i][reversed(i) ? 'end' : 'start']),
        endHeight: height(raw[i][reversed(i) ? 'start' : 'end']))];
  }
  Future<void> _syncDecorations() async {
    if (!mounted || host == null) return;
    final items = [for (final decoration in _storedDecorations)
      {'segments': _segments(decoration.range),
        'color': '#${((decoration.color.toARGB32() << 8) | (decoration.color.toARGB32() >> 24))
          .toUnsigned(32).toRadixString(16).padLeft(8, '0')}',
        'note': decoration.noteId != null, 'link': hexOf(readingLinkColor(widget.settings.theme))}];
    await host?.evaluateJavascript(source: 'window.gtScroll?.setDecorations(${jsonEncode(items)})');
  }
  void _initSelection() {
    _selectionBackend = ScrollSelectionBackend(native: true, motion: _selectionMotion,
      contentTap: (point) async {
        final action = await _selectionCommand('gtScroll.actionAt(${point.dx},${point.dy})');
        if (action is! Map || !mounted) return false;
        await _message({...Map<String, dynamic>.from(action), 'request': _request});
        return true;
      },
      hit: (point) async {
        final raw = await _selectionCommand('gtScroll.hitText(${point.dx},${point.dy})');
        return raw is Map ? _selectionMap(raw['index'] as int)?.locatorAt(Map<String, Object?>.from(raw)) : null;
      },
      sentence: (point) async {
        await _stopNativeScroll();
        final raw = await _selectionCommand('gtScroll.hitText(${point.dx},${point.dy})');
        if (raw is! Map) return null;
        final range = _selectionMap(raw['index'] as int)?.sentenceAt(Map<String, Object?>.from(raw));
        return range == null ? null : SelectionRange(start: range.start, end: range.end);
      },
      measure: _measureRanges,
      decorate: (items) async { _storedDecorations = items; await _syncDecorations(); },
      move: (distance) async {
        await host?.evaluateJavascript(source:
          'if(gtScroll.ready&&!gtScroll.busy){scrollBy(0,$distance);gtScroll.report();gtScroll.maintain()}');
        if (mounted) _selectionMotion.value++;
      });
  }
}
