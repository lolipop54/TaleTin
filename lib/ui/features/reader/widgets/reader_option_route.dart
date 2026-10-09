import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../view_models/reader_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import 'reader_option_autosave.dart';
import 'reader_panel_motion.dart';
import 'reader_sheet.dart';
import 'reader_toolbar.dart';
import 'reader_control_theme.dart';

/// 音色、定时和字体使用同一个上滑位置；根导航只负责当前子层的返回。
Future<T?> showReaderOption<T>(
  BuildContext context,
  WidgetRef ref,
  WidgetBuilder builder, {
  String? bookId,
  bool shrinkWrap = false,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final container = ProviderScope.containerOf(context);
  final vm = container.read(readerProvider.notifier);
  final parent = container.read(readerProvider).panel;
  final reduced = MediaQuery.disableAnimationsOf(context);
  ReaderPanel? nextPanel;
  var restored = false;
  late final ReaderOptionController controller;
  controller = ReaderOptionController((next) async {
    if (next != null && bookId != null) {
      try {
        await prepareReaderPanel(navigator.context, container, bookId, next);
      } catch (_) {
        vm.showNotice('面板准备失败，请重试');
        return;
      }
    }
    nextPanel = next;
    controller.allowPop();
    navigator.pop();
  });
  vm.coverPanel();
  try {
    if (!reduced) await Future<void>.delayed(readerPanelHandoffDuration);
    if (!navigator.mounted || container.read(readerProvider).panel != parent) {
      return null;
    }
    final route = PageRouteBuilder<T>(
      opaque: false,
      transitionDuration: reduced ? Duration.zero : readerPanelEnterDuration,
      reverseTransitionDuration: reduced
          ? Duration.zero
          : readerPanelExitDuration,
      pageBuilder: (context, animation, _) => UncontrolledProviderScope(
        container: container,
        child: ReaderControlTheme(
          bookId: bookId,
          child: ReaderOptionScope(
            controller: controller,
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => PopScope(
                canPop: controller.canPop,
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) controller.close();
                },
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      bottom: readerPanelBottom(context),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: controller.close,
                        child: Container(color: ReaderSheet.scrimOf(context)),
                      ),
                    ),
                    ReaderPanelViewport(
                      child: FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position:
                              Tween(
                                begin: const Offset(0, 1),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                  reverseCurve: Curves.easeInCubic,
                                ),
                              ),
                          child: Builder(
                            builder: (context) => shrinkWrap
                                ? builder(context)
                                : SizedBox(
                                    height:
                                        MediaQuery.sizeOf(context).height * .78,
                                    child: builder(context),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    if (bookId != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SafeArea(
                          top: false,
                          child: Consumer(
                            builder: (context, ref, _) => ReaderToolbar(
                              theme: ref
                                  .watch(readerSettingsProvider(bookId))
                                  .value!
                                  .theme,
                              blocked: parent,
                              onSelect: controller.busy
                                  ? null
                                  : controller.close,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final result = await navigator.push(route);
    // 子层退出约 80% 时在其下方恢复父层，剩余退出与父层进入重叠。
    if (!reduced) await Future<void>.delayed(readerPanelHandoffDuration);
    if (navigator.mounted) {
      if (nextPanel != null) {
        vm.openPanel(nextPanel!);
      } else if (container.read(readerProvider).panel == parent) {
        vm.revealPanel();
      }
      restored = true;
    }
    await route.completed;
    return result;
  } finally {
    controller.dispose();
    if (!restored && navigator.mounted && nextPanel != null) {
      vm.openPanel(nextPanel!);
    } else if (!restored &&
        navigator.mounted &&
        container.read(readerProvider).panel == parent) {
      vm.revealPanel();
    }
  }
}
