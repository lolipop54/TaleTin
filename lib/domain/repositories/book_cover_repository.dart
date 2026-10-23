import 'dart:typed_data';

import '../models/book_cover_choice.dart';
import '../models/book.dart';

abstract class BookCoverRepository {
  Future<Map<BookFormat, BookCoverChoice>> loadGlobal();
  Future<void> saveGlobal(
    BookFormat format, {
    BookCoverPreset? preset,
    Uint8List? image,
  });

  /// 不传预设或图片时恢复默认；整批准备成功后才发布新选择。
  Future<void> save(
    Iterable<String> ids, {
    BookCoverPreset? preset,
    Uint8List? image,
  });
}
