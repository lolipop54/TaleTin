import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'app_errors.dart';

/// A normal build keeps timings in memory and writes only slow or failed opens.
/// Book IDs are only used to connect the shelf, route and background work.
abstract final class PdfOpeningDiagnostics {
  static final _attempts = <String, PdfOpeningAttempt>{};
  static final _zoneKey = Object();
  static const _scopes = {
    'shelf.open.lookup',
    'reader.prepare-source',
    'source.prepare-or-reuse',
    'source.restore-saved-locations',
    'source.wait_pending_import',
    'source.verify_digest',
    'source.reparse',
    'reader.prepare_session',
    'pdf.open_handle',
    'pdf.initialize',
    'pdf.open_document',
    'pdf.prepare_bitmap',
    'pdf.read_page_content',
    'pdf.raster',
    'pdf.bitmap',
    'pdf.initial_viewport',
  };

  static void begin(String bookId, {int? bytes}) {
    final attempt = _attempts.putIfAbsent(
      bookId,
      () => PdfOpeningAttempt(write: AppErrors.store.appendPdfOpening),
    );
    if (bytes != null) attempt.identify(bytes);
  }

  static void identify(String bookId, int? bytes) {
    final attempt = _attempts[bookId];
    if (bytes == null) {
      if (attempt != null && !attempt._isPdf) finish(bookId, 'other_format');
    } else {
      attempt?.identify(bytes);
    }
  }

  static void mark(String bookId, String phase) =>
      _attempts[bookId]?.mark(phase);

  static void readingPage(
    String bookId, {
    required int page,
    required int pageCount,
    required String mode,
    required bool scrolling,
  }) => _attempts[bookId]?.readingPage(page, pageCount, mode, scrolling);

  static PdfOpeningAttempt? forWork(String scope, Object? bookId) {
    if (_attempts.isEmpty || !_scopes.contains(scope)) return null;
    // A nested render/source call may have no book ID. Inherit only the scope
    // of the call that is actually preparing this opening.
    return bookId is String
        ? _attempts[bookId]
        : Zone.current[_zoneKey] as PdfOpeningAttempt?;
  }

  static void finish(String bookId, String status) =>
      _attempts.remove(bookId)?.finish(status);
}

class PdfOpeningAttempt {
  PdfOpeningAttempt({
    required this.write,
    this.threshold = const Duration(seconds: 2),
  });

  final Future<void> Function(Map<String, Object?>) write;
  final Duration threshold;
  final _startedAt = DateTime.now();
  final _clock = Stopwatch()..start();
  final _phases = <String, int>{};
  final _longest = <String, int>{};
  final _pending = <Object, (String, int)>{};
  Timer? _timer;
  int? _bytes, _page, _pageCount;
  String? _mode, _failedStage;
  bool? _scrolling;
  bool _finished = false;
  bool get _isPdf => _bytes != null;

  void identify(int bytes) {
    if (_isPdf || _finished) return;
    _bytes = bytes;
    _timer = Timer(threshold - _clock.elapsed, () => _record('waiting'));
  }

  void mark(String phase) =>
      _phases.putIfAbsent(phase, () => _clock.elapsedMilliseconds);

  void readingPage(int page, int pageCount, String mode, bool scrolling) {
    _page = page;
    _pageCount = pageCount;
    _mode = mode;
    _scrolling = scrolling;
  }

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    if (_finished) return action();
    final token = Object();
    final start = _clock.elapsedMilliseconds;
    _pending[token] = (stage, start);
    try {
      return await runZoned(
        action,
        zoneValues: {PdfOpeningDiagnostics._zoneKey: this},
      );
    } catch (_) {
      // Preserve the innermost failed step and let the original handler run.
      _failedStage ??= stage;
      rethrow;
    } finally {
      _longest.update(
        stage,
        (old) => math.max(old, _clock.elapsedMilliseconds - start),
        ifAbsent: () => _clock.elapsedMilliseconds - start,
      );
      _pending.remove(token);
    }
  }

  void finish(String status) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    if (_isPdf &&
        (_clock.elapsed >= threshold ||
            _failedStage != null ||
            status == 'prepare_failed')) {
      _record(status == 'ok' && _failedStage != null ? 'failed' : status);
    }
  }

  void _record(String status) {
    final elapsed = _clock.elapsedMilliseconds;
    final pendingMs = <String, int>{};
    for (final (stage, start) in _pending.values) {
      final age = elapsed - start;
      pendingMs.update(stage, (old) => math.max(old, age), ifAbsent: () => age);
    }
    unawaited(
      write({
        'kind': 'pdfOpening',
        'time': _startedAt.toIso8601String(),
        'status': status,
        'elapsedMs': elapsed,
        'bytes': _bytes,
        'page': _page,
        'pageCount': _pageCount,
        'mode': _mode,
        'scrolling': _scrolling,
        'milestonesMs': {..._phases},
        'longestStageMs': {..._longest},
        'pendingStageMs': pendingMs,
        if (_failedStage != null) 'failedStage': _failedStage,
      }).catchError((Object _) {
        developer.log('PDF 打开诊断写入失败', name: 'TaleTin.diagnostics');
      }),
    );
  }
}
