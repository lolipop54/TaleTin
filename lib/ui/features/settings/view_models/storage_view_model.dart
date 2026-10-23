import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../app/di/app_providers.dart';
import '../../../../domain/repositories/storage_repository.dart';
import '../../../../data/repositories/file_storage_repository.dart';
import '../../../../data/repositories/file_chapter_content_repository.dart';

final storageRepositoryProvider = Provider<StorageRepository>((ref) {
  final listening = ref.watch(listeningServiceProvider);
  final contents = ref.watch(chapterContentRepositoryProvider);
  return FileStorageRepository(
    supportRoot: p.dirname(ref.watch(libraryRootPathProvider)),
    cacheRoot: ref.watch(cacheRootPathProvider),
    originals: ref.watch(epubSourceRepositoryProvider),
    clearChapterCache: contents is FileChapterContentRepository
        ? contents.clearChapterCache
        : null,
    clearLayoutCache: () async {
      ref.read(readerEngineProvider).invalidateLayout();
      await ref.read(layoutCheckpointStoreProvider)?.clear();
    },
    protectedBooks: () => {
      if (listening.snapshot.hasSession) listening.snapshot.bookId,
    },
  );
});
final storageUsageProvider =
    AsyncNotifierProvider.autoDispose<StorageUsageNotifier, StorageUsage>(
      StorageUsageNotifier.new,
    );

class StorageUsageNotifier extends AsyncNotifier<StorageUsage> {
  @override
  Future<StorageUsage> build() => ref.watch(storageRepositoryProvider).load();
  Future<void> refresh() async {
    final value = await ref.read(storageRepositoryProvider).load();
    if (ref.mounted) state = AsyncData(value);
  }

  Future<void> clear() async {
    try {
      await ref.read(storageRepositoryProvider).clearCache();
    } finally {
      await refresh();
    }
  }
}

String storageSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GiB';
}
