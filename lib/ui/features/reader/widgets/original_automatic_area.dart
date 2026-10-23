part of 'original_reader_area.dart';

extension _OriginalAutomaticArea on _OriginalReaderAreaState {
  Widget _automaticArea({
    required String bookId,
    required ScanPage page,
    required bool Function() ready,
    required Future<ScanPreparation> Function(ValueChanged<ui.Image>) prepare,
    required Rect bounds,
    required Rect frameBounds,
    required Color paper,
    required Color line,
    required Widget child,
  }) {
    if (!widget.settings.spreadEnabled) {
      return AutomaticScanArea(
        key: _scanKey,
        bookId: bookId,
        page: page,
        ready: ready,
        prepare: prepare,
        bounds: bounds,
        frameBounds: frameBounds,
        paper: paper,
        line: line,
        child: child,
      );
    }
    return TimedPageTurn(
      bookId: bookId,
      ready: ready,
      revision: page.layout,
      turn: () async {
        final before = (widget.session.chapterIndex, _page);
        _timedTurning = true;
        try {
          await _curlKey.currentState?.turn(true);
          return before != (widget.session.chapterIndex, _page);
        } finally {
          _timedTurning = false;
        }
      },
      child: child,
    );
  }
}
