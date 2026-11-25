import 'dart:typed_data';

import '../models/book_cover_choice.dart';
import '../models/book.dart';

abstract class BookCoverRepository {
  static const maxImagesPerImport = 9;

  /// 将旧版按单书和格式保存的图片合并进共享图库。
  Future<void> prepareGallery();
  Future<List<String>> images();
  Future<List<String>> addImages(Stream<Uint8List> images);
  Future<void> removeImage(String path);

  Future<Map<String, BookCoverChoice>> loadBooks(Iterable<String> ids);
  Future<Map<BookFormat, BookCoverChoice>> loadGlobal();
  Future<void> saveGlobal(
    BookFormat format, {
    BookCoverPreset? preset,
    Uint8List? image,
    String? existingImage,
  });

  /// 不传预设或图片时恢复默认；整批准备成功后才发布新选择。
  Future<void> save(
    Iterable<String> ids, {
    BookCoverPreset? preset,
    Uint8List? image,
    String? existingImage,
  });
}
