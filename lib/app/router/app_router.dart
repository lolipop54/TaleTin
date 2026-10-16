import '../di/book_group_providers.dart';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/achievement_providers.dart';
import '../di/app_providers.dart';
import '../di/app_font_providers.dart';
import '../di/completion_providers.dart';
import '../di/reading_controls_providers.dart';
import '../../ui/features/achievements/view_models/statistics_providers.dart';
import '../../ui/features/achievements/widgets/achievement_wall.dart';
import '../../ui/features/settings/view_models/listening_preferences.dart';
import '../../ui/features/reader/view_models/listening_panel_view_model.dart';
import '../../ui/features/reader/view_models/listening_view_state.dart';
import '../../ui/features/settings/view_models/settings_view_model.dart';

import 'main_exit_scope.dart';
import 'main_pages_ready.dart';
import 'main_navigation_bar.dart';
import 'reader_route_page.dart';
import '../../ui/core/widgets/frame_fade.dart';

import '../../ui/features/achievements/views/achievements_view.dart';
import '../../ui/features/bookshelf/views/bookshelf_view.dart';
import '../../ui/features/import/views/local_files_view.dart';
import '../../ui/features/reader/views/reader_view.dart';
import '../../ui/features/settings/views/settings_view.dart';

/// 路由约定（设计文档 3.1）：
/// - 主导航「成就 / 书架 / 设置」用 StatefulShellRoute 保持各分支状态；
/// - 阅读页是独立全屏路由，不套主导航外壳；
/// - 路由参数只携带 ID，演示阶段书名暂用占位参数。

abstract final class AppRoutes {
  static const shelf = '/shelf';
  static const achievements = '/achievements';
  static const settings = '/settings';
  static const import = '/import';
  static String reader(String bookId) => '/reader/$bookId';
}

/// 每次创建 App 实例时新建路由，避免测试/复用时残留导航状态。
GoRouter createAppRouter() => GoRouter(
  initialLocation: AppRoutes.shelf,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          MainExitScope(child: MainShell(navigationShell: navigationShell)),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.shelf,
              builder: (_, _) => const BookshelfView(),
            ),
          ],
        ),
        StatefulShellBranch(
          preload: true,
          routes: [
            GoRoute(
              path: AppRoutes.achievements,
              builder: (_, _) => const AchievementsView(artPrepared: true),
            ),
          ],
        ),
        StatefulShellBranch(
          preload: true,
          routes: [
            GoRoute(
              path: AppRoutes.settings,
              builder: (_, _) => const SettingsView(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(path: AppRoutes.import, builder: (_, _) => const LocalFilesView()),
    GoRoute(
      path: '/reader/:bookId',
      pageBuilder: (_, state) => ReaderRoutePage(
        key: state.pageKey,
        bookId: state.pathParameters['bookId'],
        child: ReaderView(bookId: state.pathParameters['bookId']!),
      ),
    ),
  ],
);

/// 底部主导航外壳：成就 / 书架 / 设置，启动默认进入书架。
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  StatefulNavigationShell get navigationShell => widget.navigationShell;
  Future<void>? _art;
  int _navigationRequest = 0;
  bool _ready = false, _holdingFirstFrame = true;
  final _fadeKey = GlobalKey<FrameFadeState>();

  @override
  void initState() {
    super.initState();
    // 首次点击也要立即切换：保留启动画面直到两个首页的数据和素材已准备。
    WidgetsBinding.instance.deferFirstFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_art == null) {
      _art = prepareAchievementArt(context);
      _prepareFirstFrame();
    }
  }

  Future<void> _prepareFirstFrame() async {
    await Future.wait([
      MainNavigationBar.prepareIcons(context),
      ref
          .read(bookGroupsProvider.future)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ref
          .read(libraryBooksProvider.future)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      // 系统或用户选中的应用字体就绪后才释放首帧，避免字体闪换。
      ref
          .read(appFontFamilyProvider.future)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      _prepareBranch(1),
      _prepareBranch(2),
    ]);
    if (!mounted) return;
    setState(() => _ready = true);
    // 先让两个隐藏分支收到就绪通知并完成布局，再释放系统启动画面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _releaseFirstFrame();
      // 当前应用字体已就绪；完整字体目录仍在首页显示后提前准备。
      if (mounted) ref.read(fontFamilyNamesProvider.future).ignore();
    });
  }

  void _releaseFirstFrame() {
    if (!_holdingFirstFrame) return;
    _holdingFirstFrame = false;
    WidgetsBinding.instance.allowFirstFrame();
  }

  @override
  void dispose() {
    _releaseFirstFrame();
    super.dispose();
  }

  Future<void> _prepareBranch(int index) async {
    final preparation = <Future<Object?>>[
      if (index == 1) ...[
        ref.read(statisticsPageProvider.future),
        ref.read(bookCompletionsProvider.future),
        ref.read(achievementPageProvider.future),
        _art!,
      ],
      if (index == 2) ...[
        ref.read(globalLayoutModeProvider.future),
        ref.read(globalPageTurnProvider.future),
        ref.read(readingControlsProvider.future),
        ref.read(statusInfoVisibleProvider.future),
        ref.read(listeningPreferencesProvider.future),
        ref.read(listeningViewStateProvider.future),
        ref
            .read(listeningVoicesProvider.future)
            .then<void>((_) {})
            .timeout(kTtsPageConnectionWait, onTimeout: () {}),
      ],
    ];
    // 首次极早点击时保留当前页；失败也交给目标页原有错误/重试界面。
    await Future.wait(
      preparation.map(
        (future) =>
            future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
  }

  Future<void> _goBranch(int index) async {
    if (_fadeKey.currentState?.busy == true) return;
    final request = ++_navigationRequest;
    await _prepareBranch(index);
    if (!mounted || request != _navigationRequest) return;
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 在可见的外壳订阅：Riverpod 会暂停隐藏分支的监听，单靠路由预载不够。
    // 保持首页数据就绪，切换时复用；后台更新仍来自原数据库/服务。
    ref.listen(bookGroupsProvider, (_, _) {});
    ref.listen(statisticsPageProvider, (_, _) {});
    ref.listen(bookCompletionsProvider, (_, _) {});
    ref.listen(achievementPageProvider, (_, _) {});
    ref.listen(globalLayoutModeProvider, (_, _) {});
    ref.listen(globalPageTurnProvider, (_, _) {});
    ref.listen(readingControlsProvider, (_, _) {});
    ref.listen(statusInfoVisibleProvider, (_, _) {});
    ref.listen(listeningPreferencesProvider, (_, _) {});
    // 超过一秒仍保留订阅，让后台连接继续，完成或超时后照常更新界面。
    ref.listen(listeningVoicesProvider, (_, _) {});
    ref.listen(listeningViewStateProvider, (_, _) {});
    return MainPagesReady(
      ready: _ready,
      isCurrent: ModalRoute.isCurrentOf(context) ?? true,
      child: Scaffold(
        // 让页面内容画到曲线凹口背后；各页把底栏高度作为列表末尾留白。
        extendBody: true,
        body: FrameFade(
          key: _fadeKey,
          revision: navigationShell.currentIndex,
          child: navigationShell,
        ),
        bottomNavigationBar: MainNavigationBar(
          branchIndex: navigationShell.currentIndex,
          onSelect: _goBranch,
        ),
      ),
    );
  }
}
