part of 'simplified_scroll_area.dart';

mixin _SimplifiedScrollSelection on ConsumerState<SimplifiedScrollArea> {
  ScrollWindow get _window;
  late ScrollSelectionBackend _selectionBackend;
  ScrollSelection? _selectionModel() {
    final options = _window.options;
    if (options == null || !_window.controller.hasClients) return null;
    return ScrollSelection(chapters: [for (final entry in _window.entries) entry.layout],
      offset: _window.controller.offset, height: options.contentHeight, options: options,
      bookId: widget.bookId, version: widget.session.book.contentVersion,
      ordinals: chapterOrdinalsOf(widget.session.chapters));
  }
  void _initSelection(Future<bool> Function(Offset) contentTap) {
    List<ScrollRangeGeometry> measure(List<SelectionRange> ranges) {
      final model = _selectionModel();
      return [for (final range in ranges) model?.geometry(range) ?? const ScrollRangeGeometry([])];
    }
    _selectionBackend = ScrollSelectionBackend(motion: Listenable.merge([_window, _window.controller]),
      contentTap: contentTap,
      hit: (point) async => _selectionModel()?.hit(point),
      sentence: (point) async => _selectionModel()?.sentence(point),
      measure: (ranges) async => measure(ranges), measureSync: measure,
      move: (distance) async {
        await _window.maintain();
        if (!mounted || !_window.controller.hasClients || _window.busy) return;
        final position = _window.controller.position;
        _window.controller.jumpTo((_window.controller.offset + distance)
          .clamp(0, position.maxScrollExtent));
        _window.report();
      });
  }
}
