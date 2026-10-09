import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/locator.dart';
import '../../../../engine/selection/scroll_selection.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_highlights.dart';
import '../view_models/book_search_navigation.dart';
import '../view_models/automatic_reading.dart';
import '../view_models/listening_view_state.dart';
import 'selection_actions.dart';
import 'selection_handles.dart';
import 'thought_marker.dart';
import 'thought_popover.dart';

part 'scroll_selection_drag.dart';

typedef ScrollDecoration = ({SelectionRange range, Color color, String? noteId});
class ScrollSelectionBackend {
  const ScrollSelectionBackend({required this.motion, required this.hit,
    required this.sentence, required this.measure, required this.move,
    this.decorate, this.measureSync, this.contentTap, this.native = false});
  final Listenable motion;
  final Future<Locator?> Function(Offset) hit;
  final Future<SelectionRange?> Function(Offset) sentence;
  final Future<List<ScrollRangeGeometry>> Function(List<SelectionRange>) measure;
  final List<ScrollRangeGeometry> Function(List<SelectionRange>)? measureSync;
  final Future<void> Function(double) move;
  final Future<void> Function(List<ScrollDecoration>)? decorate;
  final bool native;
  final Future<bool> Function(Offset)? contentTap;
}

/// 两种滚动正文共用菜单和手柄；保存仍走已有笔记流程。
class ScrollSelectionLayer extends ConsumerStatefulWidget {
  const ScrollSelectionLayer({super.key, required this.bookId, required this.backend,
    required this.theme, required this.child});
  final String bookId;
  final ScrollSelectionBackend backend;
  final ReadingTheme theme;
  final Widget child;
  @override
  ConsumerState<ScrollSelectionLayer> createState() => ScrollSelectionLayerState();
}

class ScrollSelectionLayerState extends ConsumerState<ScrollSelectionLayer>
    with _ScrollSelectionDrag {
  List<ScrollRangeGeometry> _geometry = const [];
  List<Annotation> _marks = const [];
  List<ScrollDecoration> _decorations = const [];
  SelectionRange? _range;
  SelectionRange? _speechRange;
  Object? _key;
  int _version = 0;
  bool _scheduled = false;
  @override
  void initState() { super.initState(); widget.backend.motion.addListener(_schedule); }
  @override
  void didUpdateWidget(ScrollSelectionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend.motion != widget.backend.motion) {
      oldWidget.backend.motion.removeListener(_schedule); widget.backend.motion.addListener(_schedule);
    }
  }
  void _schedule() {
    // 简化正文在 ListenableBuilder 内同步画高亮，不再于帧后重复测量和补一帧。
    if (widget.backend.measureSync != null) return;
    if (_range == null && _marks.isEmpty && _speechRange == null && _geometry.isEmpty) return;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_refresh());
    });
    WidgetsBinding.instance.scheduleFrame();
  }
  Future<void> _refresh() async {
    final version = ++_version;
    final ranges = [?_range, for (final mark in _marks) mark.range, ?_speechRange];
    if (ranges.isEmpty) { if (mounted && _geometry.isNotEmpty) setState(() => _geometry = []); return; }
    final geometry = await widget.backend.measure(ranges);
    if (mounted && version == _version) setState(() => _geometry = geometry);
  }
  Future<void> begin(Offset point) async {
    await ref.read(readerSessionProvider(widget.bookId).notifier).beginManualReading();
    final range = await widget.backend.sentence(point);
    if (!mounted || range == null) return;
    final geometry = (await widget.backend.measure([range])).first;
    if (!mounted) return;
    // 初次长按只选当前屏幕看得到的那一段，两端手柄都能立即抓到。
    final visible = geometry.rects.where((r) => r.top >= 0 && r.bottom <= context.size!.height - 44).toList();
    if (visible.isEmpty) return;
    final start = geometry.start == null
      ? await widget.backend.hit(Offset(visible.first.left + 0.5, visible.first.center.dy)) : range.start;
    final end = geometry.end == null
      ? await widget.backend.hit(Offset(visible.last.right - 0.5, visible.last.center.dy)) : range.end;
    if (mounted && start != null && end != null) {
      ref.read(readerProvider.notifier).startSelection(start, end);
    }
  }
  Future<bool> tap(Offset point) async {
    // native 滚动可能刚停下，先取当前几何再判断，不能点中旧位置。
    await _refresh();
    if (!mounted) return true;
    var index = _range == null ? 0 : 1;
    for (final mark in _marks) {
      if (index >= _geometry.length) break;
      final geometry = _geometry[index++];
      if (mark.id == searchPreviewId) continue; // 搜索强调不打开笔记菜单。
      if (mark.hasBody && mark.color != null && geometry.end != null && geometry.rects.isNotEmpty) {
        final marker = thoughtMarkerRect(geometry.rects.last, context.size!.width);
        if (marker.inflate(8).contains(point)) {
          final box = context.findRenderObject()! as RenderBox;
          await showThoughtPopover(context, anchor: marker.shift(box.localToGlobal(Offset.zero)),
            body: mark.body, theme: widget.theme);
          return true;
        }
      }
      if (geometry.rects.any((r) => r.contains(point))) {
        ref.read(readerProvider.notifier).startSelection(mark.start, mark.end!, fromMark: true);
        return true;
      }
    }
    if (_range != null) { ref.read(readerProvider.notifier).clearSelection(); return true; }
    return false;
  }
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final marks = ref.watch(readerHighlightsProvider(widget.bookId));
    final speech = ref.watch(listeningViewStateProvider).value;
    final unit = speech?.bookId == widget.bookId && speech?.hasSession == true ? speech?.activeUnit : null;
    final key = (state.selection, state.selectionFromMark, marks, unit, widget.theme);
    if (_key != key) {
      _key = key; _range = state.selection;
      _speechRange = unit == null ? null : SelectionRange(start: unit.sentenceStart, end: unit.sentenceEnd);
      _marks = marks.where((a) => !a.isBookmark && a.end != null && a.color != null).toList();
      _decorations = [for (final mark in _marks)
        (range: mark.range, color: pageHighlightColorOf(mark.color), noteId: mark.hasBody ? mark.id : null),
        if (_range != null && !state.selectionFromMark)
          (range: _range!, color: const Color(0x66B7D3F6), noteId: null),
        if (unit != null) (range: SelectionRange(start: unit.sentenceStart, end: unit.sentenceEnd),
          color: widget.theme.speechHighlight, noteId: null)];
      if (widget.backend.decorate != null) unawaited(widget.backend.decorate!(_decorations));
      _schedule();
    }
    return ListenableBuilder(listenable: widget.backend.motion, builder: (context, _) {
      // Flutter 正文已有行坐标，同一帧使用新排版坐标，避免旧高亮留在新正文上。
      if (widget.backend.measureSync case final measure?) {
        final ranges = [?_range, for (final mark in _marks) mark.range, ?_speechRange];
        _geometry = ranges.isEmpty ? const [] : measure(ranges);
      }
      return LayoutBuilder(builder: (context, box) => Stack(clipBehavior: Clip.none, children: [
      if (!widget.backend.native) Positioned.fill(child: IgnorePointer(child:
        CustomPaint(painter: _ScrollMarkPainter(_geometry, _marks, _range != null,
          !state.selectionFromMark, widget.theme, _speechRange != null)))),
      Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.translucent,
        onLongPressStart: (event) => unawaited(begin(event.localPosition)),
        onTapUp: widget.backend.native ? null : (event) async {
          if (!await tap(event.localPosition) && mounted) {
            if (await widget.backend.contentTap?.call(event.localPosition) == true || !mounted) return;
            ref.read(automaticReadingProvider(widget.bookId).notifier).centerTap();
          }
        }, child: widget.child)),
      if (_range != null && _geometry.isNotEmpty) ...[
        if (!state.selectionFromMark) ...[
          if ((_dragPoint != null && !_dragAtEnd ? _dragPoint : _geometry.first.start) case final start?) _handle(start, false, box.biggest),
          if ((_dragPoint != null && _dragAtEnd ? _dragPoint : _geometry.first.end) case final end?) _handle(end, true, box.biggest),
        ],
        if (_dragPoint == null) Positioned.fill(child: SelectionActions(bookId: widget.bookId,
          state: state, rects: _geometry.first.rects, origin: Offset.zero, pageSize: box.biggest)),
      ],
    ]));
    });
  }
  @override
  void dispose() {
    ++_version; _finishDrag(rebuild: false); widget.backend.motion.removeListener(_schedule); super.dispose();
  }
}
