import 'package:path/path.dart' as p;

import '../../domain/models/book.dart';
import '../../domain/services/local_book_files.dart';
import '../../core/concurrency/background_compute.dart';

/// 完整路径已经包含文件名，不读文件内容，也不计算摘要。
class LocalImportMatcher {
  Future<Set<String>> findImported(
    List<LocalBookEntry> entries,
    List<Book> books, {
    bool Function()? cancelled,
  }) async {
    if (cancelled?.call() ?? false) return {};
    final result = await backgroundCompute(_findImported, (
      entries,
      books,
    ), enabled: entries.length + books.length >= backgroundListThreshold);
    return (cancelled?.call() ?? false) ? {} : result;
  }
}

Set<String> _findImported((List<LocalBookEntry>, List<Book>) input) {
  final (entries, books) = input;
  final paths = {
    for (final book in books)
      if (book.status != BookStatus.removed && book.localSourcePath != null)
        p.normalize(book.localSourcePath!),
  };
  return {
    for (final entry in entries)
      if (!entry.directory && paths.contains(p.normalize(entry.path)))
        entry.path,
  };
}
