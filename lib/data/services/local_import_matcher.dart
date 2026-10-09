import 'package:path/path.dart' as p;
import '../../domain/models/book.dart';
import '../../domain/services/local_book_files.dart';

/// 完整路径已经包含文件名，不读文件内容，也不计算摘要。
class LocalImportMatcher {
  Future<Set<String>> findImported(List<LocalBookEntry> entries,
      List<Book> books, {bool Function()? cancelled}) async {
    final paths = {for (final book in books)
      if (book.status != BookStatus.removed && book.localSourcePath != null)
        p.normalize(book.localSourcePath!)};
    return {for (final entry in entries)
      if (!(cancelled?.call() ?? false) && !entry.directory &&
          paths.contains(p.normalize(entry.path))) entry.path};
  }
}
