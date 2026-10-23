/// 启动准备：打开数据库、回收上次导入残留，再把准备好的实例交给界面。
///
/// 界面在准备完成前只显示稳定的加载态，不先渲染空书架（设计文档 9.7）。
library;

import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../platform/channels/reading_window.dart';

import '../platform/channels/original_webview_warmup.dart';
import '../ui/features/reader/widgets/original_font_assets.dart';

import 'restorable_app.dart';
import 'export_error_log.dart';
import '../core/diagnostics/app_errors.dart';

import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators;

import '../ui/core/theme/forui_theme.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/database/app_database.dart';
import '../data/services/backup_restore_transaction.dart';
import '../domain/services/library_file_gate.dart';
import '../data/repositories/drift_tts_settings_repository.dart';
import '../data/repositories/drift_book_repository.dart';
import '../data/repositories/file_chapter_content_repository.dart';
import '../engine/parsers/txt_text_preparation.dart';
import '../platform/channels/android_document_platform.dart';
import '../data/services/epub_source_repository.dart';
import '../data/services/tts/book_listening_source.dart';
import '../data/services/tts/listening_controller.dart';
import '../data/services/tts/listening_audio_focus.dart';
import '../data/services/tts/native_tts_engine.dart';
import '../platform/tts/native_tts_channel.dart';
import '../platform/tts/native_listening_deadline.dart';
import '../data/repositories/drift_reading_settings_repository.dart';
import '../data/repositories/drift_reading_position_repository.dart';
import '../data/services/tts/listening_position_writer.dart';
import '../data/services/tts/listening_progress.dart';
import '../domain/services/reading_position_coordinator.dart';
import '../domain/services/automatic_reading_tasks.dart';
import '../data/services/file_import_storage.dart';
import '../data/services/remove_legacy_search_cache.dart';
import '../data/services/migrate_source_content.dart';
import '../data/services/tts/listening_audio_handler.dart';
import '../data/services/tts/listening_audio_service.dart';
import '../domain/models/reading_settings.dart';
import '../domain/use_cases/recover_library.dart';
import '../domain/repositories/app_theme_repository.dart';
import '../data/repositories/drift_app_theme_repository.dart';
import '../data/repositories/drift_achievement_repository.dart';
import '../domain/services/achievement_service.dart';
import '../domain/services/reading_statistics_service.dart';
import '../data/repositories/drift_reading_statistics_repository.dart';
import '../data/repositories/drift_statistics_settings_repository.dart';

/// 启动准备的超时时间：超过后进入错误与重试，不无限停在加载态。
const Duration kStartupTimeout = Duration(seconds: 15);

/// 启动准备结果。
class BootstrapResult {
  const BootstrapResult({
    required this.database,
    required this.libraryRoot,
    required this.cacheRoot,
    required this.recovery,
    required this.globalPreferences,
    required this.listeningHandler,
    required this.positions,
    required this.automaticTasks,
    required this.statistics,
    required this.achievements,
    required this.appTheme,
    required this.contents,
    required this.originals,
    required this.fileGate,
    this.contentMigration,
  });

  final AppDatabase database;

  /// 书架文件根目录绝对路径（`files/library`）
  final String libraryRoot;

  /// 应用缓存根目录绝对路径（`cache`）；原书排版模式的可重建内容放这里
  final String cacheRoot;
  final RecoveryReport recovery;

  /// 全局阅读偏好（上次用的主题与排版），随界面一起注入
  final GlobalReadingPreferences globalPreferences;

  /// 听书的后台媒体服务 Handler。应用级保活：不进前台就只是待命，
  /// 页面进出、切换 Tab 都不影响它（设计文档 4.2、实现计划 第 9 节）。
  final ListeningAudioHandler listeningHandler;
  final ReadingPositionCoordinator positions;
  final AutomaticReadingTasks automaticTasks;
  final ReadingStatisticsService statistics;
  final AchievementService achievements;
  final AppThemeMode appTheme;
  final FileChapterContentRepository contents;
  final EpubSourceRepository originals;
  final LibraryFileGate fileGate;
  final SourceContentMigration? contentMigration;

  /// 页面已停止新操作后调用；数据库必须最后关闭。
  Future<void> close() async {
    await contentMigration?.stop();
    await listeningHandler.detachController();
    await positions.flush();
    await statistics.shutdown();
    await achievements.refresh();
    await achievements.shutdown();
    await contents.close();
    await originals.close();
    await database.close();
    _bootstrap = null;
  }
}

/// 打开数据库并完成启动恢复。
Future<BootstrapResult>? _bootstrap;
// 启动重试时后台媒体服务可能已经存在，交接入口也必须复用同一个实例。
final _automaticTasks = AutomaticReadingTasks();
Future<BootstrapResult> bootstrapApp() =>
    _bootstrap ??= prepareApp().catchError((Object error, StackTrace stack) {
      _bootstrap = null;
      Error.throwWithStackTrace(error, stack);
    });

/// 恢复交接显式传入同一路径；真机测试可用独立目录，绝不替换正式书库。
Future<BootstrapResult> prepareApp({
  Directory? supportRoot,
  Directory? cacheRoot,
  bool recoverPending = true,
}) async {
  final supportDir = supportRoot ?? await getApplicationSupportDirectory();
  final cacheDir = cacheRoot ?? await getApplicationCacheDirectory();
  await supportDir.create(recursive: true);
  await cacheDir.create(recursive: true);
  if (recoverPending) {
    await BackupRestoreTransaction(supportDir).recover();
    // 进程结束后导出/校验任务不再运行；持久回滚完成后才清它们的临时文件。
    // 恢复前自动快照位于 support/backups，不在这个清理范围内。
    for (final name in ['backup', 'notes-export']) {
      final temporary = Directory(p.join(cacheDir.path, name));
      try {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      } on FileSystemException catch (error) {
        debugPrint('导出临时文件清理失败：$error');
      }
    }
  }
  // 旧索引已不再使用，后台回收其空间；清理失败不能阻止用户打开书架。
  unawaited(
    removeLegacySearchCache(cacheDir.path).catchError((Object error) {
      debugPrint('旧全文搜索缓存清理失败：$error');
    }),
  );
  final databaseFile = File(
    p.join(supportDir.path, 'database', 'reader.sqlite'),
  );
  await databaseFile.parent.create(recursive: true);

  final database = AppDatabase.openFile(databaseFile);
  ListeningAudioHandler? boundHandler;
  ReadingStatisticsService? statistics;
  AchievementService? achievements;
  final contents = FileChapterContentRepository(
    libraryRoot: p.join(supportDir.path, 'library'),
    cacheRoot: cacheDir.path,
    // 正式启动和恢复后的服务也必须提供转码，旧中文TXT不能按UTF-8直接读取。
    textPreparation: TxtTextPreparation(platform: AndroidDocumentPlatform()),
  );
  final originals = EpubSourceRepository(
    libraryRoot: contents.libraryRoot,
    cacheRoot: cacheDir.path,
  );
  try {
    // 打开连接是懒的，先跑一次查询确认数据库真的可用
    await database.customSelect('SELECT 1').get();

    final storage = FileImportStorage(
      libraryRoot: supportDir,
      cacheRoot: cacheDir,
    );
    final recovery = await RecoverLibrary(
      books: DriftBookRepository(database),
      storage: storage,
    ).run();

    // 全局阅读偏好在这里读一次：阅读页第一帧就能用上次的主题与排版，不闪默认值
    final settings = DriftReadingSettingsRepository(database);
    final globalPreferences = GlobalReadingPreferences(
      typography: await settings.loadGlobal() ?? kBuiltinReadingSettings,
      themeId: await settings.loadThemeId(),
    );

    // 听书的后台媒体服务：这里初始化一次，之后重试启动、重建页面都复用它
    final listeningHandler = await startListeningAudioService();
    final libraryRoot = (await storage.libraryRoot()).path;
    final positions = ReadingPositionCoordinator(
      DriftReadingPositionRepository(database),
      onError: (error, stack) => AppErrors.report(error, stack, operation: '保存阅读位置失败'),
    );
    final automaticTasks = _automaticTasks;
    if (listeningHandler.service == null) {
      final ttsChannel = NativeTtsChannel();
      final speechContents = contents;
      final focus = await ListeningAudioFocus.create(
        () async => listeningHandler.service?.pause(),
      );
      listeningHandler.attachController(
        ListeningController(
          engine: NativeTtsEngine(ttsChannel),
          pauseAutomaticReading: automaticTasks.stopAll,
          audioFocus: focus,
          onContentChanged: speechContents.invalidate,
          deadline: NativeListeningDeadline(ttsChannel),
          settingsRepository: DriftTtsSettingsRepository(database),
          source: BookListeningSource(
            books: DriftBookRepository(database),
            contents: speechContents,
            originals: originals,
          ),
          positions: ListeningPositionWriter(
            positions,
            ListeningProgress(
              DriftBookRepository(database),
              speechContents,
            ).resolve,
          ),
        ),
      );
      boundHandler = listeningHandler;
    }

    statistics = ReadingStatisticsService(
      DriftReadingStatisticsRepository(database),
      onError: (error, stack) => AppErrors.report(error, stack, operation: '保存阅读统计失败'),
    );
    await statistics.initialize();
    statistics.setIdleMinutes(
      (await DriftStatisticsSettingsRepository(database).load()).idleMinutes,
    );
    statistics.attachListening(listeningHandler.service!);
    achievements = AchievementService(DriftAchievementRepository(database));
    await achievements.initialize();
    final fileGate = LibraryFileGate();
    final appTheme = await DriftAppThemeRepository(database).load();
    final migration = SourceContentMigration(
      libraryRoot: libraryRoot,
      workRoot: p.join(cacheDir.path, 'import'),
      preparation: contents.textPreparation!,
      activeBooks: () => {
        ...originals.activeBookIds,
        if (listeningHandler.service?.snapshot.hasSession == true)
          listeningHandler.service!.snapshot.bookId,
      },
    );
    // 不纳入 15 秒启动等待；UI 可先显示书架，正文服务协调单书迁移与读取。
    unawaited(
      migration
          .runLibrary(DriftBookRepository(database), contents, fileGate)
          .then((bytes) {
            debugPrint('旧书按需正文转换释放 $bytes 字节');
          })
          .catchError((Object error) {
            debugPrint('旧书转换保留原数据：$error');
          }),
    );
    return BootstrapResult(
      database: database,
      libraryRoot: libraryRoot,
      cacheRoot: cacheDir.path,
      recovery: recovery,
      globalPreferences: globalPreferences,
      listeningHandler: listeningHandler,
      positions: positions,
      automaticTasks: automaticTasks,
      statistics: statistics,
      achievements: achievements,
      appTheme: appTheme,
      contents: contents,
      originals: originals,
      fileGate: fileGate,
      contentMigration: migration,
    );
  } catch (_) {
    // 初始化失败也要关闭本次已打开的连接，回滚才能移动目录。
    await boundHandler?.detachController();
    statistics?.dispose();
    await achievements?.shutdown();
    await contents.close();
    await originals.close();
    await database.close();
    rethrow;
  }
}

/// 启动门：准备完成前显示加载态，失败时提供重试。
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _holdingFirstFrame = true;
  @override
  void initState() {
    super.initState();
    // 保留系统启动画面，避免深色偏好读出前先绘制浅色 Flutter 占位页。
    WidgetsBinding.instance.deferFirstFrame();
  }

  void _releaseFirstFrame() {
    if (!_holdingFirstFrame) return;
    _holdingFirstFrame = false;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => WidgetsBinding.instance.allowFirstFrame(),
    );
  }

  late Future<BootstrapResult> _future = _start();

  Future<BootstrapResult> _start() async {
    try {
    final result = await bootstrapApp().timeout(kStartupTimeout);
    // 保存的全局方向在首帧放行前应用，冷启动不先显示竖屏书架再旋转。
    await SystemChrome.setPreferredOrientations(
      ReadingWindow.orientations(result.globalPreferences.typography.landscape),
    );
    if (Platform.isAndroid) {
      final epub =
          await (result.database.select(result.database.books)
                ..where(
                  (book) =>
                      book.format.equals('epub') &
                      book.status.isNotValue('removed'),
                )
                ..limit(1))
              .getSingleOrNull();
      if (epub != null) {
        // 系统启动画面仍在，先完成唯一预备实例，再允许书架第一帧出现。
        await OriginalWebViewWarmup.prepareFirstView(originalWebViewSettings());
      }
    }
    return result;
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '启动准备失败');
      rethrow;
    }
  }

  @override
  void dispose() {
    _releaseFirstFrame();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _future = _start();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BootstrapResult>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          _releaseFirstFrame();
          final result = snapshot.data!;
          return RestorableApp(initial: result);
        }
        if (snapshot.hasError) {
          _releaseFirstFrame();
          return _StartupErrorApp(error: '${snapshot.error}', onRetry: _retry);
        }
        return const _StartupLoadingApp();
      },
    );
  }
}

class _StartupLoadingApp extends StatelessWidget {
  const _StartupLoadingApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: Color(0xFFF7F8FA),
      body: Center(child: SizedBox.shrink()),
    ),
  );
}

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => GtForuiTheme(child: child!),
      home: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '启动失败',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF20242B),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '本地数据没有准备好：$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF596270),
                  ),
                ),
                const SizedBox(height: 20),
                GtButton.filled(onPressed: onRetry, child: const Text('重试')),
                const SizedBox(height: 12),
                GtButton.tonal(onPressed: exportErrorLog, child: const Text('导出错误日志')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
