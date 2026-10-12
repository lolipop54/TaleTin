import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/widgets/gt_icon.dart';
import '../../view_models/reader_view_model.dart';
import '../reader_sheet.dart';
import 'bookmark_tab.dart';
import 'book_notes_tab.dart';
import 'contents_pager.dart';
import 'contents_scroll_area.dart';
import 'toc_tab.dart';

/// 目录、书签与笔记的综合面板装配入口。
class PanelContents extends ConsumerStatefulWidget {
  const PanelContents({super.key, required this.state, required this.bookId});

  final ReaderState state;
  final String bookId;

  @override
  ConsumerState<PanelContents> createState() => _PanelContentsState();
}

class _PanelContentsState extends ConsumerState<PanelContents> {
  final _searchController = TextEditingController();
  final _pagerKey = GlobalKey();
  late final _tabPosition = ValueNotifier<double>(
    widget.state.contentsTab.toDouble(),
  );

  @override
  void dispose() {
    _searchController.dispose();
    _tabPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final vm = ref.read(readerProvider.notifier);
    final colors = context.gtColors;
    const titles = ['目录', '书签', '笔记'];

    return ReaderSheet(
      title: titles[state.contentsTab],
      maxHeightFactor: 0.85,
      onClose: vm.closePanel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.borderSubtle)),
            ),
            child: Stack(
              children: [
                Row(
                  children: [
                    _tab(context, ref, 0, '目录'),
                    _tab(context, ref, 1, '书签'),
                    _tab(context, ref, 2, '笔记'),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        ValueListenableBuilder<double>(
                          valueListenable: _tabPosition,
                          builder: (_, position, _) => SizedBox(
                            height: 3,
                            child: Stack(
                              children: [
                                Positioned(
                                  left:
                                      constraints.maxWidth / 3 * position +
                                      (constraints.maxWidth / 3 - 64) / 2,
                                  width: 64,
                                  height: 3,
                                  child: ColoredBox(
                                    key: const Key('contents-tab-indicator'),
                                    color: colors.actionPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GtSpacing.s5,
              GtSpacing.s3,
              GtSpacing.s5,
              GtSpacing.s2,
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              style: GtText.body(colors.textPrimary).copyWith(fontSize: 13),
              decoration: InputDecoration(
                hintText: switch (state.contentsTab) {
                  0 => '搜索章节',
                  1 => '搜索书签',
                  _ => '搜索章节或笔记',
                },
                hintStyle: GtText.body(colors.textMuted).copyWith(fontSize: 13),
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: GtIcon(
                    GtIcons.search,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 0,
                  minHeight: 0,
                ),
                filled: true,
                fillColor: Color.lerp(
                  ReaderSheet.backgroundOf(context),
                  colors.textPrimary,
                  .045,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: GtSpacing.s3,
                  vertical: GtSpacing.s2 + 2,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(GtRadius.control),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Flexible(
            child: ContentsScrollArea(
              child: ContentsPager(
                key: _pagerKey,
                index: state.contentsTab,
                onChanged: vm.setContentsTab,
                onPositionChanged: (position) => _tabPosition.value = position,
                children: [
                  TocTab(bookId: widget.bookId, query: _searchController.text),
                  BookmarkTab(
                    bookId: widget.bookId,
                    query: _searchController.text,
                  ),
                  BookNotesTab(
                    bookId: widget.bookId,
                    query: _searchController.text,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, WidgetRef ref, int index, String label) {
    final colors = context.gtColors;
    final selected = widget.state.contentsTab == index;
    return Expanded(
      child: GtButton.raw(
        onPressed: () {
          ContentsPager.select(_pagerKey, index);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: GtSpacing.s3),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                fontWeight: FontWeight.w400,
                color: selected ? colors.actionPrimary : colors.textSecondary,
              ),
            ),
            const SizedBox(height: GtSpacing.s2),
            const SizedBox(height: 3),
          ],
        ),
      ),
    );
  }
}
