import 'dart:async';
import 'dart:io';
import '../../domain/models/book.dart';

/// 失效是显示状态，不删除书籍、分组、笔记或阅读进度。
Future<Book> checkBookSource(Book book) async {
  final path = book.localSourcePath;
  if (path == null || book.status != BookStatus.active) return book;
  return await File(path).exists()
      ? book : book.copyWith(status: BookStatus.contentMissing);
}

/// 数据准备好后整批发布；监测原文件删除/恢复，不反复查询书架数据库。
Stream<List<Book>> watchBookSources(Stream<List<Book>> books) {
  late StreamController<List<Book>> output;
  StreamSubscription<List<Book>>? subscription;
  Timer? timer;
  List<Book>? latest, shown;
  var revision = 0;
  var checking = false;
  Future<void> check({bool changed = false}) async {
    final snapshot = latest;
    if (snapshot == null || output.isClosed || (checking && !changed)) return;
    final request = ++revision;
    checking = true;
    try {
      final ready = await Future.wait(snapshot.map(checkBookSource));
      if (output.isClosed || request != revision) return;
      if (changed || shown == null || ready.length != shown!.length ||
          List.generate(ready.length, (i) => ready[i].status != shown![i].status).any((v) => v)) {
        shown = ready;
        output.add(ready);
      }
    } catch (error, stack) {
      if (!output.isClosed && request == revision) output.addError(error, stack);
    } finally {
      if (request == revision) checking = false;
    }
  }
  output = StreamController<List<Book>>(onListen: () {
    subscription = books.listen((value) {
      latest = value;
      check(changed: true);
    }, onError: output.addError);
    timer = Timer.periodic(const Duration(seconds: 2), (_) => check());
  }, onCancel: () async {
    timer?.cancel();
    ++revision;
    await subscription?.cancel();
  });
  return output.stream;
}
