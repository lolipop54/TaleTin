import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../view_models/book_search_navigation.dart';
import '../view_models/reader_progress_return.dart';
import '../view_models/book_search_controller.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import 'search_menu_appearance.dart';

final searchMenuAppearanceProvider = Provider.autoDispose
    .family<SearchMenuAppearance?, String>((ref, bookId) {
      final navigation = ref.watch(bookSearchNavigationProvider(bookId));
      final reader = ref.watch(readerProvider);
      if (reader.panel != ReaderPanel.none ||
          reader.controlsVisible ||
          reader.selection != null) {
        return null;
      }
      final theme = ref.watch(readerSettingsProvider(bookId)).value?.theme;
      final colors = (theme ?? kDefaultReadingTheme).controlsColors;
      if (navigation.highlight == null) {
        final progress = ref.watch(readerProgressReturnProvider(bookId));
        return progress.origin == null || progress.fromSlider
            ? null
            : SearchMenuAppearance(
                colors,
                previous: false,
                next: false,
                busy: progress.busy,
                returnProgress: true,
              );
      }
      final results = ref.watch(bookSearchProvider(bookId));
      final index = results.hits.indexOf(navigation.hit!);
      return SearchMenuAppearance(
        colors,
        previous: index > 0,
        next:
            index >= 0 &&
            (index + 1 < results.hits.length || results.next != null),
        busy: navigation.busy,
        activeButton: navigation.activeButton,
      );
    });

/// 分页外观在书页画布里；这里提供可读标签和点击区域，滚动时同时绘制外观。
class SearchReturnBar extends ConsumerWidget {
  const SearchReturnBar({
    super.key,
    required this.bookId,
    required this.theme,
    this.paintMenu = true,
  });
  final String bookId;
  final ReadingTheme theme;
  final bool paintMenu;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menu = ref.watch(searchMenuAppearanceProvider(bookId));
    if (menu == null) return const SizedBox.shrink();
    final vm = ref.read(bookSearchNavigationProvider(bookId).notifier);
    final progress = ref.read(readerProgressReturnProvider(bookId).notifier);
    final actions = <VoidCallback>[
      () => vm.step(-1),
      () =>
          menu.returnProgress ? progress.returnToOrigin() : vm.returnToOrigin(),
      () => vm.step(1),
      menu.returnProgress ? progress.dismiss : vm.dismiss,
    ];
    return SafeArea(
      maintainBottomViewPadding: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final rect = menu.bounds(constraints.biggest);
          return Stack(
            children: [
              if (paintMenu)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: SearchMenuPainter(menu)),
                  ),
                ),
              for (final i in menu.buttons)
                Positioned.fromRect(
                  rect: menu.button(i).shift(rect.topLeft),
                  child: Tooltip(
                    message: menu.label(i),
                    child: Semantics(
                      label: menu.label(i),
                      button: true,
                      enabled: menu.enabled(i),
                      child: Material(
                        color: Colors.transparent,
                        child: GtButton.raw(
                          key: ValueKey('search-navigation-$i'),
                          borderRadius: BorderRadius.circular(GtRadius.control),
                          onPressed: menu.enabled(i) ? actions[i] : null,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class SearchMenuPainter extends CustomPainter {
  const SearchMenuPainter(this.menu);
  final SearchMenuAppearance menu;
  @override
  void paint(Canvas canvas, Size size) => menu.paint(canvas, size);
  @override
  bool shouldRepaint(SearchMenuPainter oldDelegate) => oldDelegate.menu != menu;
}

/// 进度条与目录跳转复用同一外观；控制面板中的按钮不使用书页底部定位。
class ProgressReturnButton extends StatelessWidget {
  const ProgressReturnButton({super.key, required this.colors, required this.busy, required this.onPressed});
  final GtColors colors;
  final bool busy;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final menu = SearchMenuAppearance(colors, previous: false, next: false, busy: busy, returnProgress: true);
    return Semantics(label: '返回原进度', button: true, enabled: !busy,
      child: SizedBox(width: 142, height: 48, child: CustomPaint(
        painter: _ProgressButtonPainter(menu),
        child: GtButton.raw(onPressed: busy ? null : onPressed,
          borderRadius: BorderRadius.circular(22), child: const SizedBox.expand()))));
  }
}
class _ProgressButtonPainter extends CustomPainter {
  const _ProgressButtonPainter(this.menu);
  final SearchMenuAppearance menu;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(0, 40);
    menu.paint(canvas, size);
    canvas.restore();
  }
  @override
  bool shouldRepaint(_ProgressButtonPainter old) => old.menu != menu;
}
