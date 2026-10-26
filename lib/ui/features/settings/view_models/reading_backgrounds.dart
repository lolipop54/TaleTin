import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../data/repositories/reading_background_repository.dart';
import '../../../../domain/models/reading_background.dart';
import '../../../../platform/channels/backup_documents.dart';
import '../../../core/theme/reading_background_texture.dart';

final readingBackgroundRepositoryProvider = Provider(
  (ref) => ReadingBackgroundRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(libraryRootPathProvider),
    ref.watch(libraryFileGateProvider),
  ),
);

class ReadingBackgroundCatalog {
  const ReadingBackgroundCatalog(this.custom, this.globalId);
  final List<ReadingBackground> custom;
  final String globalId;
  List<ReadingBackground> get all => [...ReadingBackground.presets, ...custom];
  ReadingBackground find(String id) =>
      all.where((e) => e.id == id).firstOrNull ?? ReadingBackground.solid;
}

final readingBackgroundsProvider =
    AsyncNotifierProvider<ReadingBackgrounds, ReadingBackgroundCatalog>(
      ReadingBackgrounds.new,
    );

ImageProvider backgroundThumbnail(ReadingBackground choice, String root) =>
    ResizeImage(
      choice.asset != null
          ? AssetImage(choice.asset!)
          : FileImage(File(p.join(root, choice.path!))) as ImageProvider,
      width: 160,
      height: 96,
      policy: ResizeImagePolicy.fit,
    );

Future<void> _prepareThumbnail(ImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final done = Completer<void>();
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object error, StackTrace? stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  try {
    await done.future;
  } finally {
    stream.removeListener(listener);
  }
}

class ReadingBackgrounds extends AsyncNotifier<ReadingBackgroundCatalog> {
  Future<void> _writing = Future.value();
  Future<T> _queue<T>(Future<T> Function() action) {
    final result = _writing.then((_) => action());
    _writing = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<ReadingBackgroundCatalog> build() {
    ref.watch(readingBackgroundRepositoryProvider);
    return _load();
  }

  Future<ReadingBackgroundCatalog> _load() async {
    final repo = ref.read(readingBackgroundRepositoryProvider);
    final custom = await repo.customImages();
    final root = ref.read(libraryRootPathProvider);
    for (final item in [...ReadingBackground.presets, ...custom]) {
      if (item.asset != null || item.path != null) {
        await _prepareThumbnail(backgroundThumbnail(item, root));
      }
    }
    return ReadingBackgroundCatalog(custom, await repo.selection() ?? 'solid');
  }

  Future<void> selectGlobal(String id) => _queue(() async {
    await ref.read(readingBackgroundRepositoryProvider).select(id);
    if (ref.mounted) state = AsyncData(await _load());
  });
  Future<void> remove(String id) => _queue(() async {
    await ref.read(readingBackgroundRepositoryProvider).remove(id);
    if (ref.mounted) state = AsyncData(await _load());
  });
  Future<void> import() => _queue(() async {
    final current = await _load();
    final remaining = ReadingBackground.limit - current.custom.length;
    if (remaining <= 0) return;
    final uris = await BackupDocuments().pickImages(remaining);
    if (uris.isEmpty) return;
    if (uris.length > remaining) throw StateError('本次最多还能导入$remaining张背景');
    final platform = ref.read(documentPlatformProvider);
    final images = <Uint8List>[];
    // 逐张读取和解码，不把九张相册原图同时保留在内存中。
    for (final uri in uris) {
      final session = await platform.open(uri);
      final bytes = BytesBuilder(copy: false);
      try {
        while (true) {
          final chunk = await platform.readChunk(session, 1024 * 1024);
          if (chunk == null || chunk.isEmpty) break;
          // 手机高像素照片常有9～12MiB；原图按封面相同的32MiB上限读取，
          // 随后解码到最多2048像素，持久保存的仍是处理后的背景图。
          if (bytes.length + chunk.length > 32 * 1024 * 1024) {
            throw const FormatException('图片超过32 MB，请选择较小的图片');
          }
          bytes.add(chunk);
        }
      } finally {
        await platform.close(session);
      }
      final image = await decodeBackground(bytes.takeBytes());
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw StateError('背景图片转换失败');
        images.add(png.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }
    await ref.read(readingBackgroundRepositoryProvider).add(images);
    if (ref.mounted) state = AsyncData(await _load());
  });
}

/// 留在设置主页备齐字体、背景缩略图和选项，再打开完整页面。
final globalTypographyReadyProvider = FutureProvider<void>((ref) async {
  await Future.wait([
    ref.watch(currentTypographyFontsProvider.future),
    ref.watch(readingBackgroundsProvider.future),
  ]);
});
