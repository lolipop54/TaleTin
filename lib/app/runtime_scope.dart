import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../data/services/backup_snapshot.dart';
import '../data/services/file_import_storage.dart';
import '../data/services/file_layout_checkpoint_store.dart';
import '../platform/channels/reading_fonts.dart';
import 'bootstrap.dart';
import 'di/achievement_providers.dart';
import 'di/app_providers.dart';
import 'di/statistics_providers.dart';
import 'di/theme_providers.dart';

final restoreLibraryProvider = Provider<Future<void> Function(BackupSnapshot)>(
  (_) =>
      (_) async => throw StateError('恢复入口尚未初始化'),
);
final restorationNoticeProvider = Provider<String?>((_) => null);

/// 每个运行实例使用自己的容器，旧仓库不会随界面重建被重复使用。
List<Override> runtimeOverrides(BootstrapResult result) => [
  libraryFileGateProvider.overrideWithValue(result.fileGate),
  chapterContentRepositoryProvider.overrideWithValue(result.contents),
  epubSourceRepositoryProvider.overrideWithValue(result.originals),
  importStorageProvider.overrideWithValue(
    FileImportStorage(
      libraryRoot: Directory(result.libraryRoot).parent,
      cacheRoot: Directory(result.cacheRoot),
    ),
  ),
  readingStatisticsServiceProvider.overrideWithValue(result.statistics),
  achievementServiceProvider.overrideWithValue(result.achievements),
  initialAppThemeProvider.overrideWithValue(result.appTheme),
  automaticReadingTasksProvider.overrideWithValue(result.automaticTasks),
  appDatabaseProvider.overrideWithValue(result.database),
  readingPositionCoordinatorProvider.overrideWithValue(result.positions),
  libraryRootPathProvider.overrideWithValue(result.libraryRoot),
  cacheRootPathProvider.overrideWithValue(result.cacheRoot),
  layoutCheckpointStoreProvider.overrideWithValue(
    FileLayoutCheckpointStore(
      '${result.cacheRoot}/layout_checkpoints',
      fontFingerprint: ReadingFonts.layoutFingerprint,
    ),
  ),
  globalReadingPreferencesProvider.overrideWithValue(result.globalPreferences),
  listeningAudioHandlerProvider.overrideWithValue(result.listeningHandler),
  prepareListeningContentProvider.overrideWithValue(
    result.listeningHandler.suspendBookContent,
  ),
  flushListeningPositionProvider.overrideWithValue(
    result.listeningHandler.flushPosition,
  ),
  prepareListeningReaderProvider.overrideWithValue(
    result.listeningHandler.prepareReader,
  ),
];
