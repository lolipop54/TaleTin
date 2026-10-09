import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_app_bar.dart';
import '../../../core/widgets/gt_button.dart';
import 'reader_sheet.dart';
import 'reader_option_autosave.dart';
import '../../../core/widgets/gt_icon.dart';

/// 收起会保存当前选择；标题区和内容共用纸张底色。
class ListeningOptionHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const ListeningOptionHeader({super.key, required this.title, this.actions});
  final Widget title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 1);

  @override
  Widget build(BuildContext context) {
    final controller = ReaderOptionScope.maybeOf(context)!;
    return GtAppBar(
      title: title,
      centerTitle: true,
      actions: actions,
      leading: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => GtButton.icon(
          tooltip: '收起',
          onPressed: controller.busy ? null : controller.close,
          icon: GtIcon(
            GtIcons.chevronDown,
            color: context.gtColors.textPrimary,
          ),
        ),
      ),
      backgroundColor: ReaderSheet.backgroundOf(context),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: Color.lerp(
            ReaderSheet.backgroundOf(context),
            context.gtColors.textPrimary,
            .14,
          ),
        ),
      ),
    );
  }
}
