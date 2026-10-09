import '../../../domain/models/locator.dart';
import '../../../domain/services/listening_source.dart';

/// 只记录正在读取的任务。普通暂停/停止不等文件；改正文前必须等旧读取收尾。
class TrackedListeningSource implements ListeningSource {
  TrackedListeningSource(this.delegate);
  final ListeningSource delegate;
  final _pending = <String, Set<Future<void>>>{};
  final _books = <_TrackedBook>{};
  bool _closed = false;

  Future<T> read<T>(String id, Future<T> Function() action) async {
    if (_closed) throw StateError('听书正文服务已关闭');
    final future = action();
    final done = future.then<void>((_) {}, onError: (Object _) {});
    (_pending[id] ??= {}).add(done);
    try {
      return await future;
    } finally {
      _pending[id]?.remove(done);
      if (_pending[id]?.isEmpty == true) _pending.remove(id);
    }
  }

  Future<void> drain(String id) async {
    while (_pending[id]?.isNotEmpty == true) {
      await Future.wait(_pending[id]!.toList());
    }
  }

  Future<void> close() async {
    _closed = true;
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.values.expand((tasks) => tasks).toList());
    }
    for (final book in _books.toList()) { await book.close(); }
  }

  @override
  Future<ListeningBook> open(String bookId, int contentVersion) => read(
    bookId,
    () async {
      final book = _TrackedBook(this, bookId, await delegate.open(bookId, contentVersion));
      _books.add(book);
      return book;
    },
  );
}

class _TrackedBook implements ListeningBook {
  _TrackedBook(this.source, this.id, this.book);
  final TrackedListeningSource source;
  final String id;
  final ListeningBook book;
  @override
  String get title => book.title;
  @override
  get chapters => book.chapters;
  @override
  Future<Locator> chapterStart(String logicalChapterId) =>
      source.read(id, () => book.chapterStart(logicalChapterId));
  @override
  Future<SpeechWindow> window(
    Locator from, {
    required bool sentenceStart,
    required int maxLength,
  }) => source.read(
    id,
    () => book.window(from, sentenceStart: sentenceStart, maxLength: maxLength),
  );
  @override
  Future<void> close() async {
    if (!source._books.remove(this)) return;
    await book.close();
  }
}
