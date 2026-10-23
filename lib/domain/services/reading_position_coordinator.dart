import '../repositories/reading_position_repository.dart';

/// 应用级串行保存；失败交给调用方，后续保存仍可继续。
class ReadingPositionCoordinator {
  ReadingPositionCoordinator(this.repository, {this.onError});
  final ReadingPositionRepository repository;
  final void Function(Object, StackTrace)? onError;
  final _tails = <String, Future<void>>{};
  final _errors = <String, Object>{};
  final _failedPositions = <String, ReadingPosition>{};
  final _versions = <String, int>{};
  final _owners = <String, ReadingPositionSource>{};
  Object? lastError;

  int version(String bookId) => _versions[bookId] ?? 0;
  ReadingPositionSource owner(String bookId) =>
      _owners[bookId] ?? ReadingPositionSource.visual;

  /// 先使旧页面/旧播放请求失效，再等已开始的写入完成。
  Future<int> acquire(String bookId, ReadingPositionSource source) async {
    final next = version(bookId) + 1;
    _versions[bookId] = next;
    _owners[bookId] = source;
    await _tails[bookId];
    // 存储恢复后重试此前失败的确认点，不能让一次失败永久阻止交接。
    final failed = _failedPositions[bookId];
    if (failed != null) await save(failed, token: next, source: source);
    await flush(bookId);
    return next;
  }

  bool accepts(String bookId, int token, ReadingPositionSource source) =>
      version(bookId) == token && owner(bookId) == source;

  Future<void> save(
    ReadingPosition position, {
    int? token,
    ReadingPositionSource? source,
  }) {
    final id = position.locator.bookId;
    final request = token ?? version(id);
    final write = (_tails[id] ?? Future<void>.value()).then((_) async {
      if (!accepts(id, request, source ?? position.source)) return;
      await repository.save(position);
      _errors.remove(id);
      _failedPositions.remove(id);
      lastError = null;
    });
    _tails[id] = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        onError?.call(error, stack);
        _errors[id] = error;
        _failedPositions[id] = position;
        lastError = error;
      },
    );
    return write;
  }

  /// 等待已提交的保存完成，同时保留错误供退出/交接调用方处理。
  Future<void> flush([String? bookId]) async {
    if (bookId == null) {
      await Future.wait(_tails.values.toList());
      if (_errors.isNotEmpty) throw _errors.values.first;
    } else {
      await _tails[bookId];
      if (_errors[bookId] != null) throw _errors[bookId]!;
    }
  }
}
