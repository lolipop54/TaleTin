import 'dart:async';
import '../../../core/diagnostics/app_errors.dart';

import '../../../domain/models/locator.dart';
import '../../../domain/repositories/reading_position_repository.dart';
import '../../../domain/services/reading_position_coordinator.dart';

/// 只接收已确认位置；页面不存在时也能合并保存。
class ListeningPositionWriter {
  ListeningPositionWriter(this.coordinator, this.resolve);
  final ReadingPositionCoordinator coordinator;
  final Future<ReadingPosition> Function(Locator) resolve;
  void Function(Object)? onError;
  String? _bookId;
  int _token = 0;
  Locator? _pending;
  Timer? _timer;
  Timer? _heartbeat;
  Future<void> _tail = Future.value();
  Object? _failure;

  Future<void> begin(String bookId) async {
    await release();
    _token = await coordinator.acquire(bookId, ReadingPositionSource.listening);
    _bookId = bookId;
    _heartbeat = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _schedule(),
    );
  }

  void update(Locator locator) {
    if (locator.bookId != _bookId) return;
    _pending = locator;
    _timer ??= Timer(const Duration(seconds: 1), () {
      _timer = null;
      _schedule();
    });
  }

  void _schedule() {
    unawaited(
      flush().catchError((Object error, StackTrace stack) {
        AppErrors.report(error, stack, operation: '保存听书位置失败');
        onError?.call(error);
      }),
    );
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final locator = _pending;
    _pending = null;
    final token = _token;
    final write = _tail.then((_) async {
      if (locator != null) {
        final position = await resolve(locator);
        await coordinator.save(position, token: token);
        _failure = null;
      }
      if (_failure != null) throw _failure!;
      if (_bookId != null) await coordinator.flush(_bookId);
    });
    _tail = write.catchError((Object error) {
      _failure = error;
      // 写盘失败仍保留最后确认点，暂停/停止可以再次尝试。
      _pending ??= locator;
    });
    return write;
  }

  Future<void> release() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await flush();
    final id = _bookId;
    if (id != null &&
        coordinator.accepts(id, _token, ReadingPositionSource.listening)) {
      await coordinator.acquire(id, ReadingPositionSource.visual);
    }
    _bookId = null;
  }
}
