import 'package:taletin/core/diagnostics/app_errors.dart';

import '../core/diagnostics/reader_work_trace.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'di/theme_providers.dart';
import 'di/app_font_providers.dart';
import 'di/app_providers.dart';
import 'di/statistics_providers.dart';
import '../platform/channels/reading_fonts.dart';
import '../domain/repositories/app_theme_repository.dart';

import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../domain/services/listening_service.dart';

import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:go_router/go_router.dart';

import '../ui/core/theme/app_theme.dart';
import '../ui/core/theme/forui_theme.dart';
import '../ui/core/widgets/gt_scroll_input_scope.dart';
import 'router/app_router.dart';
import '../platform/channels/external_book_open.dart';
import '../ui/features/import/view_models/import_view_model.dart';
import '../ui/features/reader/view_models/reader_session_view_model.dart';
import '../ui/features/reader/view_models/reader_settings_view_model.dart';
import '../ui/features/bookshelf/view_models/prepare_shelf_return.dart';
import '../platform/channels/reading_window.dart';
import '../ui/features/settings/view_models/global_reading_settings.dart';

/// 应用根 Widget。路由实例随 App 创建，保证状态隔离。
class GTReaderApp extends ConsumerStatefulWidget {
  const GTReaderApp({super.key, this.listening});
  final ListeningService? listening;

  @override
  ConsumerState<GTReaderApp> createState() => _GTReaderAppState();
}

class _GTReaderAppState extends ConsumerState<GTReaderApp> {
  late final GoRouter _router = createAppRouter();
  StreamSubscription<bool>? _notificationClicks;
  String? _fontFamily;
  late final AppLifecycleListener _fontLifecycle;
  bool _refreshingFonts = false;
  final _externalBooks = ExternalBookOpenChannel();
  bool _openingExternal = false;
  bool _externalChanged = false;

  @override
  void initState() {
    super.initState();
    final window = ref.read(readingWindowProvider);
    unawaited(
      window.setGlobalLandscape(
        ref.read(globalReadingPreferencesProvider).typography.landscape,
      ),
    );
    ref.listenManual(globalSettingsProvider, (_, next) {
      final settings = next.value;
      if (settings != null) {
        unawaited(window.setGlobalLandscape(settings.typography.landscape));
      }
    }, fireImmediately: true);
    _router.routeInformationProvider.addListener(_updateDiagnosticRoute);
    _updateDiagnosticRoute();
    _fontLifecycle = AppLifecycleListener(
      onResume: () => unawaited(_refreshSystemFont()),
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _externalBooks.listen(_externalBookChanged);
      // 数据库已完成启动准备；等路由挂载后才处理首次文件打开。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _externalBookChanged(),
      );
    }
    if (widget.listening != null) {
      _notificationClicks = AudioService.notificationClicked.listen((clicked) {
        final state = widget.listening!.snapshot;
        if (!clicked || !state.hasSession || state.bookId.isEmpty) return;
        // 路由只传 bookId；阅读页准备时再取最新位置，避免把通知旧快照带回来。
        final location = AppRoutes.reader(state.bookId);
        if (_router.routeInformationProvider.value.uri.path != location) {
          _router.go(location);
        }
      });
    }
  }

  void _externalBookChanged() {
    if (!mounted) return;
    _externalChanged = true;
    if (!_openingExternal) unawaited(_openExternalBooks());
  }

  Future<void> _leaveExternalReader(String? targetId) async {
    final parts = _router.routeInformationProvider.value.uri.pathSegments;
    if (parts.length != 2 ||
        parts.first != 'reader' ||
        parts.last == targetId) {
      return;
    }
    await traceReaderWork('reader.exit.external_book', () async {
      // 外部换书也等待旧阅读器保存位置、设置和统计，不能直接销毁页面。
      await traceReaderWork(
        'reader.exit.external.auto_stop',
        () => ref.read(automaticReadingTasksProvider).stopAll(),
      );
      if (!mounted) return;
      await traceReaderWork(
        'reader.exit.external.settings',
        () =>
            ref.read(readerSettingsProvider(parts.last).notifier).pendingWrites,
      );
      if (!mounted) return;
      await traceReaderWork(
        'reader.exit.external.position',
        () => ref
            .read(readerSessionProvider(parts.last).notifier)
            .flushPendingPosition(),
      );
      if (!mounted) return;
      await traceReaderWork(
        'reader.exit.external.statistics',
        () => ref.read(readingStatisticsServiceProvider).leaveVisual(),
      );
      if (mounted) await prepareShelfReturn(ref);
    });
  }

  Future<void> _openExternalBooks() async {
    _openingExternal = true;
    try {
      do {
        _externalChanged = false;
        final request = await _externalBooks.next();
        if (!mounted || request == null) break;
        final imports = ref.read(importProvider.notifier);
        try {
          var id = await imports.findExternalBook(request.document);
          if (!mounted) return;
          if (id == null) {
            await _leaveExternalReader(null);
            if (!mounted) return;
            _router.go(AppRoutes.shelf);
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted) return;
            id = await imports.importExternal(request.document);
          }
          if (!mounted) return;
          if (id != null) await _leaveExternalReader(id);
          if (!mounted) return;
          final current = await _externalBooks.complete(request.id);
          if (!mounted) return;
          if (current && id != null) {
            final location = AppRoutes.reader(id);
            if (_router.routeInformationProvider.value.uri.path != location) {
              // 保留书架作为返回页；换书只替换当前阅读页，不叠放两个阅读器。
              if (_router.routeInformationProvider.value.uri.path.startsWith(
                '/reader/',
              )) {
                unawaited(_router.pushReplacement<void>(location));
              } else {
                unawaited(_router.push<void>(location));
              }
            }
          }
        } catch (error, stack) {
          if (!mounted) return;
          await _externalBooks.complete(request.id);
          AppErrors.report(error, stack, operation: '打开外部书籍失败');
        }
        // 处理期间的新请求仍由 Android 保存，继续领取；旧请求不再自动开书。
      } while (mounted);
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '接收外部书籍失败');
    } finally {
      _openingExternal = false;
      if (mounted && _externalChanged) _externalBookChanged();
    }
  }

  void _updateDiagnosticRoute() {
    final parts = _router.routeInformationProvider.value.uri.pathSegments;
    // 只记录页面名，不记录路由中的书籍ID或搜索参数。
    AppErrors.reporter.route = parts.isEmpty ? '/' : '/${parts.first}';
    AppErrors.reporter.context = {};
  }

  Future<void> _refreshSystemFont() async {
    if (_refreshingFonts) return;
    _refreshingFonts = true;
    try {
      await ReadingFonts.refreshSystem();
      if (!mounted) return;
      ref.invalidate(systemFontFamilyProvider);
      ref.invalidate(fontFamilyNamesProvider);
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '刷新系统字体失败');
      // 返回前的字体仍可正常显示；读取失败时保留它，下一次返回重新尝试。
      debugPrint('系统字体刷新失败：$error');
    } finally {
      _refreshingFonts = false;
    }
  }

  @override
  void dispose() {
    _fontLifecycle.dispose();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _externalBooks.dispose();
    }
    unawaited(_notificationClicks?.cancel());
    _router.routeInformationProvider.removeListener(_updateDiagnosticRoute);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 加载新字体时保留上一字体，文件就绪后再一次性切换整个应用。
    ref.watch(appFontFamilyProvider).whenData((family) => _fontFamily = family);
    return MaterialApp.router(
      title: 'TaleTin',
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
      theme: GtTheme.light(fontFamily: _fontFamily),
      darkTheme: GtTheme.dark(fontFamily: _fontFamily),
      themeMode: switch (ref.watch(appThemeProvider)) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      themeAnimationDuration: const Duration(milliseconds: 220),
      // 应用不再用自己的开关覆盖系统的动画设置。
      builder: (context, child) =>
          GtForuiTheme(child: GtScrollInputScope(child: child!)),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
    );
  }
}
