import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../../../domain/models/book_cover_choice.dart';
import 'martial_cover_background.dart';

/// 无损 WebP 预设图只解码一次，页面等图片准备好后再显示，避免先露出空白。
abstract final class BookCoverResources {
  static final images = <BookCoverPreset, ui.Image>{};
  static Future<void>? _loading;
  static Future<void> prepare() => _loading ??= _load();
  static Future<void> _load() async {
    for (final preset in BookCoverPreset.values) {
      if (images.containsKey(preset)) continue;
      if (preset == BookCoverPreset.martial) {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)..scale(512 / 284, 721 / 400);
        paintMartialCoverBackground(canvas);
        final picture = recorder.endRecording();
        try {
          images[preset] = await picture.toImage(512, 721);
        } finally {
          picture.dispose();
        }
        continue;
      }
      final name = preset == BookCoverPreset.parchment
          ? 'kraft_paper'
          : preset.code;
      final bytes = await rootBundle.load('assets/covers/$name.webp');
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        targetWidth: 512,
      );
      try {
        images[preset] = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    }
  }
}
