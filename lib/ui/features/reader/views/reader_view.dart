import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';

import 'dart:async';

import '../widgets/completion_prompt.dart';
import '../widgets/reader_performance.dart';

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/models/locator.dart';

import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/widgets/book_loading.dart';
import '../../../core/widgets/frame_fade.dart';
import '../../../../app/router/reader_route_page.dart';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../platform/channels/reading_window.dart';
import '../../bookshelf/view_models/prepare_shelf_return.dart';
import '../../../../app/di/statistics_providers.dart';
import '../widgets/reading_statistics_scope.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../../domain/services/screen_controls.dart';
import '../../../../domain/services/toc_entry_index.dart';
import '../../../../engine/layout/chapter_layout.dart';
import '../../../../engine/selection/selection_range.dart';
import '../../../../engine/selection/selection_rects.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/original_layout_controller.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/note_editor_controller.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/automatic_reading.dart';
import '../widgets/original_reader_area.dart';
import '../widgets/original_host_controller.dart';
import '../widgets/page_canvas.dart';
import '../widgets/simplified_scroll_area.dart';
import '../widgets/original_scroll_area.dart';
import '../widgets/reader_display_transition.dart';
import '../widgets/reader_image_viewer.dart';
import '../widgets/reader_image_gallery.dart';
import '../widgets/reader_information.dart';
import '../widgets/fold_frames.dart';
import '../widgets/automatic_scan_area.dart';
import '../widgets/scan_frames.dart';
import '../widgets/page_turn_area.dart';
import '../widgets/panel_auto.dart';
import '../widgets/book_search_page_host.dart';
import '../view_models/book_search_controller.dart';
import '../view_models/book_search_navigation.dart';
import '../view_models/reader_progress_return.dart';
import '../view_models/reader_highlights.dart';
import '../widgets/search_return_bar.dart';
import '../widgets/panel_brightness.dart';
import '../../settings/widgets/settings_slider.dart';
import '../../settings/view_models/settings_view_model.dart'
    show statusInfoVisibleProvider;
import '../widgets/panel_contents.dart';
import '../widgets/panel_tts.dart';
import '../widgets/panel_typography.dart';
import '../widgets/reader_sheet.dart';
import '../widgets/reader_control_theme.dart';
import '../widgets/reader_panel_motion.dart';
import '../widgets/reader_bookmark.dart';
import '../widgets/reader_toolbar.dart';
import '../widgets/selection_actions.dart';
import '../widgets/thought_marker.dart';
import '../widgets/thought_popover.dart';
import '../widgets/selection_handles.dart';
import '../widgets/listening_follow.dart';
import '../view_models/listening_view_state.dart';
import '../view_models/listening_panel_view_model.dart';
import '../../../../engine/selection/speech_rects.dart';
import '../../../core/widgets/gt_icon.dart';

part '../widgets/reader_content.dart';
part '../widgets/reader_page_area.dart';
part '../widgets/reader_top_bar.dart';
part '../widgets/reader_bottom_controls.dart';
part '../widgets/reader_notice.dart';
part '../widgets/note_editor_panel.dart';

/// 阅读页（参考图 02/03）。
/// 三层结构：正文层（真实排版）→ 控制层 → 子面板层。
/// 点击正文中间区域切换控制层；返回键依次关闭面板/控制层再退出。
class ReaderView extends ConsumerWidget {
  const ReaderView({super.key, required this.bookId});

  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ReaderScope(
    bookId: bookId,
    child: ListeningFollow(
      bookId: bookId,
      child: ReaderControlTheme(
        bookId: bookId,
        child: _ReaderBody(bookId: bookId),
      ),
    ),
  );
}

/// 阅读页的外围处理：窗口亮度与阅读位置。
///
/// - 亮度：本书设了覆盖就作用到窗口，离开阅读页恢复原亮度（设计文档 2.3）；
/// - 位置：应用切到后台时记一次当前位置（设计文档 7.1）。翻页、换章时已经
///   各写一次，这里补的是「读到一半直接切后台或被系统回收」；因此不依赖
///   dispose 提交数据（设计文档 4.2）。
class _ReaderScope extends ConsumerStatefulWidget {
  const _ReaderScope({required this.bookId, required this.child});

  final String bookId;
  final Widget child;

  @override
  ConsumerState<_ReaderScope> createState() => _ReaderScopeState();
}

class _ReaderScopeState extends ConsumerState<_ReaderScope> {
  late final ReadingWindow _window;
  MediaQueryData? _readingMetrics;
  late final AppLifecycleListener _lifecycle;
  late final bool _previousResampling;
  late final Duration _previousSamplingOffset;

  /// dispose 里不能再读 Provider，先把屏幕能力拿在手上
  late final ScreenControls _screen = ref.read(screenControlsProvider);
  late final AutomaticReadingNotifier _automatic;

  void _persist() {
    unawaited(
      _automatic.pause(save: false).then((_) async {
        if (!mounted) return;
        await ref
            .read(readerSessionProvider(widget.bookId).notifier)
            .flushPendingPosition();
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance
      ..resamplingEnabled = _previousResampling
      ..samplingOffset = _previousSamplingOffset;
    _lifecycle.dispose();
    unawaited(_automatic.pause(save: false));
    // 离开阅读页：窗口恢复系统亮度
    unawaited(_screen.setWindowBrightness(null));
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _window = ref.read(readingWindowProvider)..enterReading();
    final binding = WidgetsBinding.instance;
    _previousResampling = binding.resamplingEnabled;
    _previousSamplingOffset = binding.samplingOffset;
    // 将触摸移动对齐到刷新节奏，避免原书平台视图下交替出现一帧、两帧
    // 的画面间隔。使用真机验证的 8ms 短窗口，不沿用 SDK 的 38ms 默认值。
    // 仅阅读页持有此设置，退出后恢复书架等界面的原输入配置。
    binding
      ..samplingOffset = const Duration(milliseconds: -8)
      ..resamplingEnabled = !const bool.fromEnvironment(
        'GT_DISABLE_READER_RESAMPLING',
      );
    // 即使从未操作自动阅读，也要在界面有效时取得退出所需的引用。
    _automatic = ref.read(automaticReadingProvider(widget.bookId).notifier);
    // 创建时就注册后台监听；延迟到退出时创建会漏掉整次阅读期间的后台事件。
    _automatic.setForeground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final foreground = state == AppLifecycleState.resumed;
        _automatic.setForeground(foreground);
        if (!foreground) _persist();
      },
    );
    // 进页面先按当前已知的设置设一次亮度：设置还在读时是 null（跟随系统），
    // 读出来之后由下面的 listen 生效
    unawaited(
      _screen.setWindowBrightness(
        ref.read(readerSettingsProvider(widget.bookId)).value?.brightness,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(automaticReadingProvider(widget.bookId));
    ref.listen(readerProvider, (_, next) {
      if (next.panel != ReaderPanel.brightness &&
          ref.read(brightnessPreviewProvider(widget.bookId)) != null) {
        ref.read(brightnessPreviewProvider(widget.bookId).notifier).set(null);
      }
      if (next.controlsVisible ||
          next.panel != ReaderPanel.none ||
          next.selection != null ||
          next.note != null) {
        unawaited(
          next.selection != null || next.note != null
              ? _automatic.discard()
              : _automatic.pause(),
        );
      }
    });
    ref.listen(readerSettingsProvider(widget.bookId), (previous, next) {
      final old = previous?.value, current = next.value;
      if (old == null || current == null) return;
      final normalized = old.settings.copyWith(
        autoScrollSpeed: current.settings.autoScrollSpeed,
        autoScanSeconds: current.settings.autoScanSeconds,
        autoKeepAwake: current.settings.autoKeepAwake,
      );
      if (normalized == current.settings && old.theme == current.theme) {
        _automatic.updateSettings(current.settings);
      } else {
        unawaited(_automatic.discard());
      }
    });
    // 本书亮度覆盖变化立刻作用到窗口
    ref.listen(
      readerSettingsProvider(widget.bookId).select((s) => s.value?.brightness),
      (_, brightness) => unawaited(
        _screen.setWindowBrightness(
          ref.read(brightnessPreviewProvider(widget.bookId)) ?? brightness,
        ),
      ),
    );
    ref.listen(brightnessPreviewProvider(widget.bookId), (_, preview) {
      unawaited(
        _screen.setWindowBrightness(
          preview ??
              ref.read(readerSettingsProvider(widget.bookId)).value?.brightness,
        ),
      );
    });
    // 一次交接排版与滚动方式，避免恢复全局时两个回调互相覆盖位置。
    ref.listen(
      readerSettingsProvider(widget.bookId).select(
        (s) => s.value == null
            ? null
            : (
                s.value!.settings.layoutMode,
                s.value!.settings.pageTurnEffect == PageTurnEffect.scroll,
              ),
      ),
      (previous, next) {
        if (next == null || previous == next) return;
        unawaited(
          ref
              .read(readerSessionProvider(widget.bookId).notifier)
              .switchReadingDisplay(next.$1, next.$2),
        );
      },
    );
    return ValueListenableBuilder<bool>(
      valueListenable: _window.exiting,
      builder: (context, leaving, child) {
        // 恢复系统栏期间保留旧阅读画布，书架在下面按新安全区完成布局。
        if (!leaving || _readingMetrics == null) {
          _readingMetrics = MediaQuery.of(context);
        }
        return MediaQuery(
          data: _readingMetrics!,
          child: AbsorbPointer(absorbing: leaving, child: child),
        );
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _automatic.pointerDown(),
        child: widget.child,
      ),
    );
  }
}
