import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/repositories/book_cover_repository.dart';
import '../../../../platform/channels/backup_documents.dart';

final bookCoverControllerProvider = Provider(BookCoverController.new);
final bookCoverPickerProvider = Provider<Future<List<String>> Function()>(
  (_) =>
      () => BackupDocuments.forCurrentPlatform().pickCoverImages(
        BookCoverRepository.maxImagesPerImport,
      ),
);

class BookCoverController {
  BookCoverController(this.ref);
  final Ref ref;

  /// 系统选择器仅授权所选图片。解码成功后缩至封面需要的大小，
  /// 写入独立 PNG，后续不再依赖手机相册路径或临时 URI 授权。
  Future<List<String>> import() async {
    final repository = ref.read(bookCoverRepositoryProvider);
    final uris = await ref.read(bookCoverPickerProvider)();
    if (uris.isEmpty) return [];
    // 选择器返回的批次仍需核对数量，再读取用户选中的图片。
    const limit = BookCoverRepository.maxImagesPerImport;
    if (uris.length > limit) {
      throw const FormatException('一次最多导入 $limit 张封面，请重新选择');
    }
    Stream<Uint8List> images() async* {
      for (final uri in uris) {
        yield await _decode(uri);
      }
    }

    return repository.addImages(images());
  }

  Future<Uint8List> _decode(String uri) async {
    final platform = ref.read(documentPlatformProvider);
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
      return png.buffer.asUint8List();
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
