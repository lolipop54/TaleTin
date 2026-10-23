import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/bookshelf_view_model.dart';
import 'shelf_action_button.dart';

/// 排序与布局共用一个弹出菜单；排序沿用保存成功后才更新书架的规则。
class ShelfMoreMenu extends ConsumerWidget {
  const ShelfMoreMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final shelf = ref.watch(bookshelfProvider);
    final vm = ref.read(bookshelfProvider.notifier);
    return FPopoverMenu(
      // 透明遮挡层拦住整次外部点击；放到根弹层后也能覆盖底部主导航。
      overlayLocation: OverlayChildLocation.rootOverlay,
      cutout: false,
      hideRegion: FPopoverHideRegion.anywhere,
      style: FPopoverMenuStyleDelta.delta(
        barrierFilter: () => _transparentBarrier,
        itemGroupStyle: const FItemGroupStyleDelta.delta(spacing: GtSpacing.s0),
      ),
      menuAnchor: Alignment.topRight,
      childAnchor: Alignment.bottomRight,
      divider: FItemDivider.full,
      menuBuilder: (menuContext, controller, _) => [
        FItemGroup(
          children: [
            _heading('排序', colors),
            for (final (sort, label) in const [
              (ShelfSort.title, '按文件名'),
              (ShelfSort.imported, '按导入时间'),
              (ShelfSort.recent, '按最近阅读'),
            ])
              _option(
                key: ValueKey('shelf-sort-${sort.name}'),
                label: label,
                selected: shelf.sort == sort,
                colors: colors,
                enabled: !shelf.savingSort,
                onPressed: () async {
                  try {
                    await vm.setSort(sort);
                    if (context.mounted) await controller.hide();
                  } catch (appError, appStack) {
                    AppErrors.report(appError, appStack, operation: '排序设置未保存', notify: false);
                    if (context.mounted) {
                      AppErrors.report(appError, appStack, operation: '排序设置未保存');
                    }
                  }
                },
              ),
          ],
        ),
        FItemGroup(
          children: [
            _heading('布局', colors),
            for (final (grid, label, icon) in const [
              (true, '网格布局', GtIcons.grid),
              (false, '列表布局', GtIcons.list),
            ])
              _option(
                key: ValueKey(grid ? 'shelf-layout-grid' : 'shelf-layout-list'),
                label: label,
                icon: icon,
                selected: shelf.gridView == grid,
                colors: colors,
                onPressed: () async {
                  if (ref.read(bookshelfProvider).gridView != grid) {
                    vm.toggleViewMode();
                  }
                  await controller.hide();
                },
              ),
          ],
        ),
      ],
      builder: (context, controller, _) => ShelfActionButton(
        key: const ValueKey('shelf-more'),
        tooltip: '更多',
        icon: GtIcons.moreVertical,
        onPressed: controller.toggle,
      ),
    );
  }

  static ColorFilter _transparentBarrier(BuildContext context, double value) =>
      const ColorFilter.mode(Colors.transparent, BlendMode.srcOver);

  FItem _heading(String label, GtColors colors) => FItem.raw(
    key: ValueKey('shelf-menu-heading-$label'),
    enabled: false,
    semanticsButton: false,
    // 分区名不是禁用的选项，明确取消 Forui 禁用状态的灰底和大内边距。
    style: const FItemStyleDelta.delta(
      backgroundColor: FVariants.all(Colors.transparent),
      contentDecoration: FVariants.all(BoxDecoration()),
      rawContentStyle: FRawItemContentStyleDelta.delta(
        padding: EdgeInsetsGeometryDelta.value(
          EdgeInsets.symmetric(
            horizontal: GtSpacing.s2,
            vertical: GtSpacing.s1,
          ),
        ),
      ),
    ),
    child: Text(
      label,
      style: GtText.caption(Color.lerp(colors.textMuted, colors.surface, 0.25)!)
          .copyWith(fontSize: 12, height: 1.25),
    ),
  );

  FItem _option({
    required Key key,
    required String label,
    required bool selected,
    required GtColors colors,
    required VoidCallback onPressed,
    String? icon,
    bool enabled = true,
  }) {
    final color = selected ? colors.actionPrimary : colors.textPrimary;
    return FItem(
      key: key,
      style: const FItemStyleDelta.delta(
        contentStyle: FItemContentStyleDelta.delta(
          suffixedPadding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(
              horizontal: GtSpacing.s2,
              vertical: GtSpacing.s2,
            ),
          ),
          unsuffixedPadding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(
              horizontal: GtSpacing.s2,
              vertical: GtSpacing.s1,
            ),
          ),
        ),
      ),
      enabled: enabled,
      onPress: onPressed,
      semanticsChecked: selected,
      prefix: icon == null ? null : GtIcon(icon, size: 18, color: color),
      title: Text(
        label,
        style: GtText.body(color).copyWith(fontSize: 15, height: 1.4),
      ),
      suffix: SizedBox(
        width: 18,
        child: selected ? GtIcon(GtIcons.check, size: 18, color: color) : null,
      ),
    );
  }
}
