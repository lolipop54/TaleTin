import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'di/theme_providers.dart';
import 'di/app_font_providers.dart';
import 'di/app_providers.dart';
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

  @override
  void initState() {
    super.initState();
    _fontLifecycle = AppLifecycleListener(
      onResume: () => unawaited(_refreshSystemFont()),
    );
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

  Future<void> _refreshSystemFont() async {
    if (_refreshingFonts) return;
    _refreshingFonts = true;
    try {
      await ReadingFonts.refreshSystem();
      if (!mounted) return;
      ref.invalidate(systemFontFamilyProvider);
      ref.invalidate(fontFamilyNamesProvider);
    } catch (error) {
      // 返回前的字体仍可正常显示；读取失败时保留它，下一次返回重新尝试。
      debugPrint('系统字体刷新失败：$error');
    } finally {
      _refreshingFonts = false;
    }
  }

  @override
  void dispose() {
    _fontLifecycle.dispose();
    unawaited(_notificationClicks?.cancel());
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
