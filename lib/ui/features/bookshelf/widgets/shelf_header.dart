import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/decorations.dart';
import '../../../core/widgets/gt_expandable_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/bookshelf_view_model.dart';
import '../../../core/widgets/gt_round_action_button.dart';
import 'shelf_more_menu.dart';

/// 标题与搜索保持同一个生命周期，进入多选只替换标题行。
class ShelfHeader extends ConsumerStatefulWidget {
  const ShelfHeader({
    super.key,
    required this.height,
    required this.onImport,
    this.selectionHeader,
  });

  final double height;
  final VoidCallback onImport;
  final Widget? selectionHeader;

  @override
  ConsumerState<ShelfHeader> createState() => _ShelfHeaderState();
}

class _ShelfHeaderState extends ConsumerState<ShelfHeader>
    with SingleTickerProviderStateMixin, GtExpandableSearch<ShelfHeader> {
  @override
  String get searchKey => 'shelf-search';
  @override
  String get searchHint => '搜索本地书籍';
  @override
  String get initialSearchText => ref.read(bookshelfProvider).query;
  @override
  void onSearchChanged(String value) =>
      ref.read(bookshelfProvider.notifier).setQuery(value);

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('shelf-header'),
          height: widget.height,
          child:
              widget.selectionHeader ??
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  GtSize.shelfPagePadding,
                  GtSpacing.s4,
                  GtSpacing.s4,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: FoldCornerHeading(
                          defaultTargetPlatform == TargetPlatform.windows
                              ? '书架'
                              : 'TaleTin',
                          pageTitle: true,
                          style: GtText.pageTitle(
                            colors.textPrimary,
                          ).copyWith(fontSize: 24, fontFamily: GtFonts.serif),
                        ),
                      ),
                    ),
                    buildSearchButton(),
                    const SizedBox(width: GtSpacing.s2),
                    GtRoundActionButton(
                      key: const ValueKey('shelf-import'),
                      tooltip: '导入书籍',
                      icon: GtIcons.folderPlus,
                      onPressed: widget.onImport,
                    ),
                    const SizedBox(width: GtSpacing.s2),
                    const ShelfMoreMenu(),
                  ],
                ),
              ),
        ),
        buildSearchField(context),
      ],
    );
  }
}
