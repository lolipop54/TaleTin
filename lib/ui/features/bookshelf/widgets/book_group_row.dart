import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/gt_button.dart';

/// 整行用于移动书籍，右侧手柄单独接管拖动，避免拖动时误选分组。
class BookGroupRow extends StatelessWidget {
  const BookGroupRow({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
    this.dragIndex,
    this.onMoveUp,
    this.onMoveDown,
    this.onDelete,
  });
  final String name;
  final bool selected;
  final VoidCallback? onTap, onMoveUp, onMoveDown, onDelete;
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
          if (dragIndex != null)
            GtButton.icon(
              key: ValueKey('book-group-delete-$name'),
              tooltip: '删除分组$name',
              onPressed: onDelete,
              icon: Image.asset(
                'assets/icons_used/删除.png',
                width: 22,
                height: 22,
                cacheWidth: 88,
                color: colors.danger,
                colorBlendMode: BlendMode.srcIn,
                excludeFromSemantics: true,
              ),
            ),
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
                enabled: onTap != null,
                child: SizedBox(
                  width: 48,
                  height: 64,
                  child: Icon(Icons.menu, color: colors.textMuted, size: 24),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
