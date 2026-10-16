import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';

/// 三个选项始终并排；选中只改变底色，文字各自预览实际字重。
class FontWeightTabs extends StatelessWidget {
  const FontWeightTabs({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtle,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (weight, label) in const [
              (400, '正常'),
              (500, '半粗'),
              (700, '加粗'),
            ])
              Expanded(
                child: Semantics(
                  selected: value == weight,
                  child: GtButton(
                    key: ValueKey('font-weight-$weight'),
                    style: GtButton.compactStyle.copyWith(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      backgroundColor: WidgetStatePropertyAll(
                        value == weight ? colors.surface : Colors.transparent,
                      ),
                      foregroundColor: WidgetStatePropertyAll(
                        value == weight
                            ? colors.actionPrimary
                            : colors.textSecondary,
                      ),
                    ),
                    onPressed: () {
                      if (value != weight) onChanged(weight);
                    },
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.values[weight ~/ 100 - 1],
                        ),
                      ),
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
