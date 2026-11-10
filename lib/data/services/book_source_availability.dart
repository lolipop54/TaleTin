import 'dart:async';
import 'dart:io';

import '../../domain/models/book.dart';

/// 失效是显示状态，不删除书籍、分组、笔记或阅读进度。
Future<Book> checkBookSource(Book book) async {
  final path = book.localSourcePath;
  if (path == null || book.status != BookStatus.active) return book;
  return await File(path).exists()
      ? book
      : book.copyWith(status: BookStatus.contentMissing);
}

/// 首次订阅核对来源，之后的数据库更新只合并元数据。
/// 返回书架、恢复前台由调用方重新订阅，不在停留或滚动时轮询文件。
Stream<List<Book>> watchBookSources(
  Stream<List<Book>> books, {
  Future<Book> Function(Book)? checkSource,
}) {
  late StreamController<List<Book>> output;
  StreamSubscription<List<Book>>? subscription;
  List<Book>? latest, shown;
  var revision = 0;
  var checking = false;
  Future<void> check() async {
    final snapshot = latest;
    if (snapshot == null || output.isClosed) return;
    final request = ++revision;
    checking = true;
    try {
      final ready = <Book>[];
      final inspect = checkSource ?? checkBookSource;
      // 文件IO虽异步，启动请求、接收结果和后续判断仍在主isolate。
      // 不一次对全书库派发数千个请求；每批之间让滚动和绘制先执行。
      for (var start = 0; start < snapshot.length; start += 8) {
        if (output.isClosed || request != revision) return;
        ready.addAll(
          await Future.wait(snapshot.skip(start).take(8).map(inspect)),
        );
        if (start + 8 < snapshot.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (output.isClosed || request != revision) return;
      shown = ready;
      output.add(ready);
    } catch (error, stack) {
      if (!output.isClosed && request == revision) {
        output.addError(error, stack);
      }
    } finally {
      if (request == revision) checking = false;
    }
  }

  output = StreamController<List<Book>>(
    onListen: () {
      subscription = books.listen((value) {
        final previous = latest;
        latest = value;
        if (shown == null || checking) {
          check();
          return;
        }
        // 进度、封面、分组等数据库更新不触发文件检查。
        // 仅给同一来源、同一正文版本和同一存储状态沿用已核对的显示状态。
        final stored = {for (final book in previous!) book.id: book};
        final statuses = {for (final book in shown!) book.id: book.status};
        shown = [
          for (final book in value)
            _withKnownStatus(book, stored[book.id], statuses[book.id]),
        ];
        output.add(shown!);
      }, onError: output.addError);
    },
    onCancel: () async {
      ++revision;
      await subscription?.cancel();
    },
  );
  return output.stream;
}

Book _withKnownStatus(Book book, Book? previous, BookStatus? status) {
  if (previous == null ||
      status == null ||
      status == book.status ||
      previous.sourceHash != book.sourceHash ||
      previous.contentVersion != book.contentVersion ||
      previous.status != book.status) {
    return book;
  }
  return book.copyWith(status: status);
}
