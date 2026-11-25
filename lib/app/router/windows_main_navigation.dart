import 'package:flutter/material.dart';

import '../../ui/core/theme/app_theme.dart';
import '../../ui/core/theme/gt_tokens.dart';
import '../../ui/core/widgets/gt_button.dart';
import 'main_navigation_bar.dart';

class WindowsMainNavigation extends StatelessWidget {
  const WindowsMainNavigation({
    super.key,
    required this.branchIndex,
    required this.onSelect,
    required this.compact,
    required this.selectingBooks,
  });

  final int branchIndex;
  final ValueChanged<int> onSelect;
  final bool compact;
  final bool selectingBooks;

  Widget _icon(BuildContext context, int branch, Color color) => Image(
    image: MainNavigationBar.iconImage(
      MainNavigationBar.icons[MainNavigationBar.branches.indexOf(branch)],
      context,
    ),
    width: 23,
    height: 23,
    color: color,
    colorBlendMode: BlendMode.srcIn,
    excludeFromSemantics: true,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final radius = BorderRadius.circular(9);
    return SizedBox(
      width: compact ? 82 : 202,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.lerp(colors.surface, colors.subtle, .30),
          border: Border(right: BorderSide(color: colors.borderSubtle)),
        ),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            compact ? 8 : 14,
            20,
            compact ? 8 : 14,
            16,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: SizedBox(
                height: 32,
                child: Padding(
                  padding: EdgeInsets.only(left: compact ? 0 : 12),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: compact
                        ? Alignment.center
                        : Alignment.centerLeft,
                    child: Text(
                      'TaleTin',
                      style: GtText.pageTitle(colors.textPrimary)
                          .copyWith(fontSize: compact ? 15 : 22),
                    ),
                  ),
                ),
              ),
            ),
            for (final (index, label) in const [
              (0, '书架'),
              (1, '统计'),
              (2, '设置'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: GtButton.raw(
                  key: ValueKey('main-nav-$index'),
                  selected: branchIndex == index,
                  borderRadius: radius,
                  onPressed: selectingBooks ? null : () => onSelect(index),
                  child: Container(
                    height: compact ? 55 : 45,
                    padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 12),
                    decoration: BoxDecoration(
                      color: branchIndex == index
                          ? colors.actionPrimary.withValues(alpha: .11)
                          : Colors.transparent,
                      borderRadius: radius,
                    ),
                    child: compact
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _icon(
                                context,
                                index,
                                branchIndex == index
                                    ? colors.actionPrimary
                                    : colors.textSecondary,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                label,
                                style: GtText.caption(colors.textPrimary),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              _icon(
                                context,
                                index,
                                branchIndex == index
                                    ? colors.actionPrimary
                                    : colors.textSecondary,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                label,
                                style: GtText.body(
                                  branchIndex == index
                                      ? colors.actionPrimary
                                      : colors.textPrimary,
                                  weight: branchIndex == index
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
