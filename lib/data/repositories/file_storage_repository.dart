import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../domain/repositories/storage_repository.dart';
import '../../platform/channels/windows_storage_scan.dart';
import '../services/epub_source_repository.dart';

class FileStorageRepository implements StorageRepository {
  FileStorageRepository({
    required this.supportRoot,
    required this.cacheRoot,
    required this.originals,
    required this.protectedBooks,
    this.readInstalledStorage,
    this.windowsExecutablePath,
    this.clearChapterCache,
    this.clearLayoutCache,
  });
  final String supportRoot, cacheRoot;
  final EpubSourceRepository originals;
  final Set<String> Function() protectedBooks;
  final Future<InstalledStorage?> Function()? readInstalledStorage;
  final String? windowsExecutablePath;
  final Future<void> Function()? clearChapterCache;
  final Future<void> Function()? clearLayoutCache;
  @override
  Future<StorageUsage> load() async {
    final support = supportRoot, cache = cacheRoot;
    final executable = windowsExecutablePath;
    final protected = {...protectedBooks(), ...originals.activeBookIds};
    final installed = await readInstalledStorage?.call();
    return Isolate.run(
      () => _scan(support, cache, protected, installed, executable),
    );
  }

  @override
  Future<void> clearCache() async {
    await clearChapterCache?.call();
    await clearLayoutCache?.call();
    await originals.preparations.clear();
    // 使用中的原书/听书、导入暂存、真实字体、WebView 内部缓存均不碰。
    for (final name in ['original', 'mobi', 'reading']) {
      final root = Directory(p.join(cacheRoot, name));
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is! Directory) continue;
          if (name != 'original') {
            if (entity.path == p.join(root.path, '.pins') ||
                {
                  ...protectedBooks(),
                  ...originals.activeBookIds,
                }.contains(p.basename(entity.path))) {
              continue;
            }
            if (!p.isWithin(root.path, entity.path)) {
              throw const FormatException('缓存书籍路径越界');
            }
            await entity.delete(recursive: true);
            continue;
          }
          final detached = originals.detachUnusedCache(
            entity,
            protectedBooks(),
          );
          if (detached != null) await detached.delete(recursive: true);
        }
      }
    }
    for (final name in ['search', 'cleanup']) {
      final directory = Directory(p.join(cacheRoot, name));
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

Future<StorageUsage> _scan(
  String support,
  String cache,
  Set<String> protected,
  InstalledStorage? installed,
  String? windowsExecutable,
) async {
  final categories = <String, int>{
    '源书': 0,
    '正文与资源': 0,
    '数据库': 0,
    (windowsExecutable == null ? '字体资源' : '导入字体'): 0,
    '自动备份快照': 0,
    '缓存（含使用中）': 0,
    '其他运行数据': 0,
  };
  var clearable = 0;
  void count(String root, String path, int length) {
    final parts = p.split(p.relative(path, from: root));
    var category = '其他运行数据';
    if (root == cache) {
      category =
          windowsExecutable == null &&
              parts.first.startsWith('gt-device-') &&
              parts.first.endsWith('.ttf')
          ? '字体资源'
          : '缓存（含使用中）';
      if (parts.first == 'search' ||
          parts.first == 'cleanup' ||
          parts.first == 'chapters' ||
          parts.first == 'layout_checkpoints' ||
          parts.first == 'original_prepared' ||
          ({'original', 'mobi', 'reading'}.contains(parts.first) &&
              parts.length > 2 &&
              !protected.contains(parts[1]))) {
        clearable += length;
      }
    } else if (parts.first == 'database') {
      category = '数据库';
    } else if (parts.first == 'backups') {
      category = '自动备份快照';
    } else if (parts.first == 'fonts') {
      if (windowsExecutable == null) {
        category = '字体资源';
      } else if (parts.length == 3 &&
          parts[1] == 'imported' &&
          p.extension(path) == '.ttf') {
        // 导入的 TTF、OTF、TTC 字形都由字体库按摘要保存为 .ttf 文件。
        category = '导入字体';
      }
    } else if (parts.first == 'library' && parts.length > 2) {
      // source.path 只记录原书位置，与正文索引一起统计，不作为源书副本。
      category = parts[2].startsWith('source.') && parts[2] != 'source.path'
          ? '源书'
          : '正文与资源';
    }
    categories[category] = categories[category]! + length;
  }

  for (final root in [support, cache]) {
    if (Platform.isWindows) {
      scanWindowsStorage(root, (path, length) => count(root, path, length));
      continue;
    }
    final directory = Directory(root);
    if (!await directory.exists()) continue;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      int length;
      try {
        length = await entity.length();
      } on FileSystemException {
        if (!await entity.exists()) continue;
        rethrow;
      }
      count(root, entity.path, length);
    }
  }
  return StorageUsage(
    Map.unmodifiable(categories),
    clearable,
    installed: installed,
    windowsProgram: windowsExecutable == null
        ? null
        : readWindowsProgramStorage(windowsExecutable),
  );
}
