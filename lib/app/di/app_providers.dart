/// 基础设施 Provider：把契约绑定到具体实现（设计文档 4.1 / 4.2）。
///
/// 这里是唯一的组合入口；Repository 与 Use Case 都通过构造函数注入依赖，
/// 不接收 `Ref`。数据库实例由 `bootstrap` 创建后 override，便于测试替换。
library;

import 'dart:async';

import 'device_status_providers.dart';

import '../../domain/services/library_file_gate.dart';
import '../../domain/repositories/listening_timer_repository.dart';
import '../../data/repositories/drift_listening_timer_repository.dart';
import '../../domain/repositories/tts_settings_repository.dart';
import '../../data/repositories/drift_tts_settings_repository.dart';

import '../../domain/services/automatic_reading_tasks.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/services/backfill_source_locations.dart';
import '../../data/services/source_position_preparation.dart';
import '../../core/diagnostics/position_experiments.dart';
import 'package:path/path.dart' as p;

import '../../data/database/app_database.dart';
import '../../data/repositories/drift_annotation_repository.dart';
import '../../data/repositories/direct_book_search_repository.dart';
import '../../data/services/book_search_source.dart';
import '../../domain/repositories/book_search_repository.dart';
import '../../data/repositories/drift_book_repository.dart';
import '../../data/repositories/drift_note_draft_repository.dart';
import '../../data/repositories/drift_reading_position_repository.dart';
import '../../data/repositories/drift_reading_settings_repository.dart';
import '../../data/repositories/file_chapter_content_repository.dart';
import '../../data/services/epub_source_repository.dart';
import '../../data/services/file_import_storage.dart';
import '../../data/services/tts/listening_audio_handler.dart';
import '../../domain/models/book.dart';
import '../../domain/models/reading_settings.dart';
import '../../domain/repositories/annotation_repository.dart';
import '../../domain/repositories/book_repository.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../domain/repositories/note_draft_repository.dart';
import '../../domain/repositories/reading_position_repository.dart';
import '../../domain/repositories/reading_settings_repository.dart';
import '../../domain/services/book_parser.dart';
import '../../domain/services/document_platform.dart';
import '../../domain/services/font_resolver.dart';
import '../../domain/services/screen_controls.dart';
import '../../domain/services/import_storage.dart';
import '../../domain/services/listening_service.dart';
import '../../domain/services/book_content_change.dart';
import '../../domain/services/reader_engine.dart';
import '../../domain/services/reading_position_coordinator.dart';
import '../../domain/services/text_preparation.dart';
import '../../domain/use_cases/delete_books.dart';
import '../../domain/use_cases/import_books.dart';
import '../../engine/layout/flutter_reader_engine.dart';
import '../../engine/parsers/parser_registry.dart';
import '../../engine/parsers/txt_text_preparation.dart';
import '../../platform/channels/android_document_platform.dart';
import '../../platform/channels/android_font_resolver.dart';
import '../../platform/channels/reading_fonts.dart';
import '../../platform/channels/android_screen_controls.dart';
import '../../platform/tts/tts_system_settings.dart';

/// 导入、删除与备份共用同一个文件变更等待器。
final libraryFileGateProvider = Provider<LibraryFileGate>(
  (_) => LibraryFileGate(),
);

/// 应用数据库；由 `main` 在 ProviderScope override 中注入。
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => throw StateError('appDatabaseProvider 必须在 ProviderScope 中注入'),
);

final bookRepositoryProvider = Provider<BookRepository>(
  (ref) => DriftBookRepository(
    ref.watch(appDatabaseProvider),
    libraryRoot: ref.watch(libraryRootPathProvider),
  ),
);

final bookSearchRepositoryProvider = Provider<BookSearchRepository>(
  (ref) => DirectBookSearchRepository(
    BookSearchSource(
      ref.watch(bookRepositoryProvider),
      ref.watch(chapterContentRepositoryProvider),
    ),
  ),
);

/// 阅读设置与单书覆盖（设计文档 2.3 / 7.1）。
final readingSettingsRepositoryProvider = Provider<ReadingSettingsRepository>(
  (ref) => DriftReadingSettingsRepository(ref.watch(appDatabaseProvider)),
);

/// 标注（书签 / 高亮 / 笔记，共用 annotations 表）。
final annotationRepositoryProvider = Provider<AnnotationRepository>(
  (ref) => DriftAnnotationRepository(ref.watch(appDatabaseProvider)),
);

/// 笔记草稿（写一半的想法，按书一份，见实现计划 N4）。
final noteDraftRepositoryProvider = Provider<NoteDraftRepository>(
  (ref) => DriftNoteDraftRepository(ref.watch(appDatabaseProvider)),
);

/// 阅读位置（设计文档 7.1）：退出/切后台时写入，打开书时恢复。
final readingPositionRepositoryProvider = Provider<ReadingPositionRepository>(
  (ref) => DriftReadingPositionRepository(ref.watch(appDatabaseProvider)),
);

final readingPositionCoordinatorProvider = Provider<ReadingPositionCoordinator>(
  (ref) =>
      ReadingPositionCoordinator(ref.watch(readingPositionRepositoryProvider)),
);

/// 全局阅读偏好：`bootstrap` 读库后注入，保证阅读页第一帧就是用户上次的主题
/// 与排版（AGENTS 规则 8）。未注入时按内置默认值（测试与首帧兜底）。
final globalReadingPreferencesProvider = Provider<GlobalReadingPreferences>(
  (ref) => GlobalReadingPreferences.defaults,
);

/// 文件选择与 URI 分块读取的平台能力。
final documentPlatformProvider = Provider<DocumentPlatform>(
  (ref) => AndroidDocumentPlatform(),
);

/// 屏幕能力：窗口亮度与电量（S14）。
final screenControlsProvider = Provider<ScreenControls>(
  (ref) => AndroidScreenControls(),
);

/// 系统亮度（0–1）：跟随系统时界面用它显示当前值；拿不到时为 null。
final systemBrightnessProvider = FutureProvider<double?>(
  (ref) => ref.watch(screenControlsProvider).systemBrightness(),
);

/// 电量百分比 0–100；拿不到时为 null（状态行显示用）。
final batteryLevelProvider = FutureProvider.autoDispose<int?>((ref) {
  ref.watch(deviceStatusChangesProvider);
  return ref.watch(screenControlsProvider).batteryLevel();
});

/// 字体名解析：问系统「这个字体族实际用的是哪个字体」。
final fontResolverProvider = Provider<FontResolver>(
  (ref) => AndroidFontResolver(),
);

/// 字体全部加载完成后一次返回，面板不先显示固定或重复的占位字体。
final fontFamilyNamesProvider = FutureProvider<Map<String, String?>>(
  (ref) => ReadingFonts.load(),
);

final importStorageProvider = Provider<ImportStorage>(
  (ref) => FileImportStorage(),
);

final parserRegistryProvider = Provider<BookParserRegistry>(
  (ref) => ParserRegistry(),
);

final textPreparationProvider = Provider<TextPreparationService>(
  (ref) => TxtTextPreparation(platform: ref.watch(documentPlatformProvider)),
);

final importBooksProvider = Provider<ImportBooksUseCase>(
  (ref) => ImportBooksUseCase(
    fileGate: ref.watch(libraryFileGateProvider),
    books: ref.watch(bookRepositoryProvider),
    platform: ref.watch(documentPlatformProvider),
    storage: ref.watch(importStorageProvider),
    parsers: ref.watch(parserRegistryProvider),
    textPreparation: ref.watch(textPreparationProvider),
    prepareContentChange: ref.watch(bookContentChangeProvider),
    loadSourcePositions: (id) => loadSourcePositionPreparation(
      ref.read(appDatabaseProvider), ref.read(libraryRootPathProvider), id),
    optimizeLocations: PositionExperiments.optimizedFlow,
  ),
);

/// 书架文件根目录的绝对路径（`files/library`）；由 bootstrap 注入。
///
/// 数据库里存的是相对书籍目录的路径，界面用它拼出可读的绝对路径。
final libraryRootPathProvider = Provider<String>(
  (ref) => throw StateError('libraryRootPathProvider 必须在 ProviderScope 中注入'),
);

/// 阅读引擎：排版与位置换算的入口（设计文档 4.3）。
/// 应用级保活：排版缓存跨页面复用（设计文档 4.2）。
final readerEngineProvider = Provider<ReaderEngine>(
  (ref) => FlutterReaderEngine(),
);

/// 应用缓存目录（`cache`）；由 bootstrap 注入。
///
/// 原书排版模式解出的章节与字体会落在它下面的 `original/`（可重建缓存）。
final cacheRootPathProvider = Provider<String>(
  (ref) => throw StateError('cacheRootPathProvider 必须在 ProviderScope 中注入'),
);

/// 原书排版模式的内容服务（读 source.epub，见 docs/原书排版模式实现计划.md）。
final epubSourceRepositoryProvider = Provider<EpubSourceRepository>(
  (ref) => EpubSourceRepository(
    libraryRoot: ref.watch(libraryRootPathProvider),
    cacheRoot: ref.watch(cacheRootPathProvider),
  ),
);

/// 章节正文与资源读取（正文文件的事实来源，见实现计划 4.5 节）。
final chapterContentRepositoryProvider = Provider<ChapterContentRepository>((
  ref,
) {
  final contents = FileChapterContentRepository(
    libraryRoot: ref.watch(libraryRootPathProvider),
    textPreparation: ref.watch(textPreparationProvider),
    cacheRoot: ref.watch(cacheRootPathProvider),
  );
  ref.onDispose(() {
    unawaited(contents.close());
  });
  return contents;
});

/// 把书籍的相对封面路径解析成绝对路径；无封面时返回 null。
final bookCoverFileProvider = Provider<String? Function(Book)>((ref) {
  final root = ref.watch(libraryRootPathProvider);
  return (book) {
    final relative = book.coverPath;
    return relative == null ? null : p.join(root, book.id, relative);
  };
});

/// 删除书籍用例（长按多选删除）。
final deleteBooksProvider = Provider<DeleteBooks>(
  (ref) => DeleteBooks(
    fileGate: ref.watch(libraryFileGateProvider),
    prepareContentChange: ref.watch(bookContentChangeProvider),
    books: ref.watch(bookRepositoryProvider),
    storage: ref.watch(importStorageProvider),
  ),
);

/// 听书的后台媒体服务；由 `bootstrap` 启动后注入（应用级保活）。
///
/// 不在这里直接 `AudioService.init`：那个方法每个进程只能调一次，
/// 放在 Provider 里会因为监听数变化或自动释放重复触发（实现计划 第 9 节）。
final listeningAudioHandlerProvider = Provider<ListeningAudioHandler>(
  (ref) =>
      throw StateError('listeningAudioHandlerProvider 必须在 ProviderScope 中注入'),
);

/// 页面只读契约；实例由 Handler 持有，不受 Provider 监听数影响。
final listeningServiceProvider = Provider<ListeningService>(
  (ref) =>
      ref.watch(listeningAudioHandlerProvider).service ??
      (throw StateError('听书服务尚未完成启动')),
);

final listeningTimerRepositoryProvider = Provider<ListeningTimerRepository>(
  (ref) => DriftListeningTimerRepository(ref.watch(appDatabaseProvider)),
);

final ttsSettingsRepositoryProvider = Provider<TtsSettingsRepository>(
  (ref) => DriftTtsSettingsRepository(ref.watch(appDatabaseProvider)),
);

final automaticReadingTasksProvider = Provider<AutomaticReadingTasks>(
  (_) => AutomaticReadingTasks(),
);

/// 启动时注入；独立阅读器测试可以不初始化 Android 媒体插件。
final prepareListeningReaderProvider =
    Provider<Future<ReadingPosition?> Function(String)>(
      (_) =>
          (_) async => null,
    );

/// 书架数据流：数据库是唯一事实来源，写入后界面自动更新。
final libraryBooksProvider = StreamProvider<List<Book>>(
  (ref) => ref.watch(bookRepositoryProvider).watchActiveBooks(),
);

/// 可复用的文件交接：后台停读完成后允许变更，完成/失败均清掉正文与排版缓存。
final prepareListeningContentProvider = Provider<PrepareBookContentChange>(
  (_) =>
      (_) async => () {},
);
final prepareSearchContentProvider = Provider<PrepareBookContentChange>(
  (ref) =>
      (bookId) =>
          ref.read(bookSearchRepositoryProvider).prepareContentChange(bookId),
);
final bookContentChangeProvider = Provider<PrepareBookContentChange>((ref) {
  final prepare = ref.watch(prepareListeningContentProvider);
  final prepareSearch = ref.watch(prepareSearchContentProvider);
  final contents = ref.watch(chapterContentRepositoryProvider);
  final engine = ref.watch(readerEngineProvider);
  return (bookId) async {
    final releaseAutomatic = await ref
        .read(automaticReadingTasksProvider)
        .suspendBook(bookId);
    late void Function() release;
    void Function()? releaseSearch;
    void Function()? releaseReader, releaseOriginal;
    try {
      release = await prepare(bookId);
      // 听书先保存最后确认点，再收回旧页面/旧播放的写入权。
      try {
        await ref.read(readingPositionCoordinatorProvider).acquire(bookId, ReadingPositionSource.visual);
      } catch (_) { release(); rethrow; }
    } catch (_) {
      releaseAutomatic();
      rethrow;
    }
    try {
      // 删除或重解析前等待读取收尾；正文交接期间阻止旧搜索继续读取。
      releaseSearch = await prepareSearch(bookId);
      if (contents is FileChapterContentRepository) {
        await backfillSourceLocations(ref.read(appDatabaseProvider), bookId,
          (chapter) => contents.cachedPreviousChapter(bookId, chapter));
        await preserveSourcePositionProof(ref.read(appDatabaseProvider),
          ref.read(libraryRootPathProvider), bookId);
        releaseReader = await contents.prepareContentChange(bookId);
      }
      releaseOriginal = await ref
          .read(epubSourceRepositoryProvider)
          .prepareContentChange(bookId);
    } catch (_) {
      releaseReader?.call();
      releaseSearch?.call();
      release();
      releaseAutomatic();
      rethrow;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      contents.invalidate(bookId);
      engine.invalidateLayout(bookId: bookId);
      releaseOriginal?.call();
      releaseReader?.call();
      releaseSearch?.call();
      release();
      ref.read(automaticReadingTasksProvider).contentChanged(bookId);
      releaseAutomatic();
    };
  };
});

final flushListeningPositionProvider = Provider<Future<void> Function()>(
  (_) => () async {},
);

final ttsSystemSettingsProvider =
    Provider<Future<bool> Function(String?, bool)>(
      (_) => openTtsSystemSettings,
    );
