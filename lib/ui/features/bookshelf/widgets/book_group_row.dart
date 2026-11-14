import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';

/// 行名用于移动书籍，右侧放管理按钮或排序手柄。
class BookGroupRow extends StatelessWidget {
  const BookGroupRow({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
    this.showActions = false,
    this.dragIndex,
    this.dragEnabled = false,
    this.onMoveUp,
    this.onMoveDown,
    this.onEdit,
    this.onDelete,
  });
  final String name;
  final bool selected;
  final bool showActions, dragEnabled;
  final VoidCallback? onTap, onMoveUp, onMoveDown, onEdit, onDelete;
  final int? dragIndex;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: GtButton.raw(
              onPressed: onTap,
              selected: selected,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    name,
                    style: GtText.body(
                      selected ? colors.actionPrimary : colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (showActions) ...[
            GtButton.icon(
              key: ValueKey('book-group-edit-$name'),
              tooltip: '编辑分组$name',
              onPressed: onEdit,
              icon: GtIcon(
                GtIcons.pencil,
                size: 22,
                color: onEdit == null ? colors.textMuted : colors.textPrimary,
              ),
            ),
            GtButton.icon(
              key: ValueKey('book-group-delete-$name'),
              tooltip: '删除分组$name',
              onPressed: onDelete,
              icon: Image.asset(
                'assets/icons_used/删除.webp',
                width: 22,
                height: 22,
                cacheWidth: 88,
                color: onDelete == null ? colors.textMuted : colors.danger,
                colorBlendMode: BlendMode.srcIn,
                excludeFromSemantics: true,
              ),
            ),
          ],
          if (dragIndex != null)
            Semantics(
              label: '拖动调整$name的顺序',
              customSemanticsActions: {
                const CustomSemanticsAction(label: '上移'): ?onMoveUp,
                const CustomSemanticsAction(label: '下移'): ?onMoveDown,
              },
              child: ReorderableDragStartListener(
                key: ValueKey('book-group-drag-$name'),
                index: dragIndex!,
                enabled: dragEnabled,
                child: SizedBox(
                  width: 48,
                  height: 64,
                  child: Center(
                    child: GtIcon(GtIcons.reorder, color: colors.textMuted),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
