import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/book_cover_choice.dart';
import '../../../../domain/models/book.dart';
import '../../../../platform/channels/backup_documents.dart';

final bookCoverControllerProvider = Provider(BookCoverController.new);

class BookCoverController {
  BookCoverController(this.ref);
  final Ref ref;

  Future<void> select(Iterable<String> ids, BookCoverPreset? preset) =>
      ref.read(bookCoverRepositoryProvider).save(ids, preset: preset);

  /// 系统选择器仅授权所选图片。解码成功后缩至封面需要的大小，
  /// 写入独立 PNG，后续不再依赖手机相册路径或临时 URI 授权。
  Future<bool> import(Iterable<String> ids, {BookFormat? format}) async {
    final repository = ref.read(bookCoverRepositoryProvider);
    final platform = ref.read(documentPlatformProvider);
    final uri = await BackupDocuments().pickImage();
    if (uri == null) return false;
    final session = await platform.open(uri);
    final bytes = BytesBuilder(copy: false);
    try {
      while (true) {
        final chunk = await platform.readChunk(session, 1024 * 1024);
        if (chunk == null || chunk.isEmpty) break;
        if (bytes.length + chunk.length > 32 * 1024 * 1024) {
          throw const FormatException('图片超过 32 MB，请选择较小的图片');
        }
        bytes.add(chunk);
      }
    } finally {
      await platform.close(session);
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes.takeBytes());
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final ratio =
          1200 /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      codec = await descriptor.instantiateCodec(
        targetWidth: ratio < 1
            ? (descriptor.width * ratio).round().clamp(1, 1200)
            : null,
        targetHeight: ratio < 1
            ? (descriptor.height * ratio).round().clamp(1, 1200)
            : null,
      );
      image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('图片转换失败');
      if (format != null) {
        await repository.saveGlobal(format, image: png.buffer.asUint8List());
      } else {
        await repository.save(ids, image: png.buffer.asUint8List());
      }
      return true;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
