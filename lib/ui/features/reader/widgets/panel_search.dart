import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:taletin/ui/core/widgets/gt_list_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../view_models/book_search_controller.dart';
import '../view_models/book_search_navigation.dart';
import 'contents/contents_scroll_area.dart';
import 'reader_sheet.dart';

class PanelSearch extends ConsumerStatefulWidget {
  const PanelSearch({super.key, required this.bookId});
  final String bookId;
  @override
  ConsumerState<PanelSearch> createState() => _PanelSearchState();
}

class _PanelSearchState extends ConsumerState<PanelSearch> {
  late final _input = TextEditingController(
    text: ref.read(bookSearchProvider(widget.bookId)).query,
  );
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bookSearchProvider(widget.bookId));
    final vm = ref.read(bookSearchProvider(widget.bookId).notifier);
    final navigation = ref.watch(bookSearchNavigationProvider(widget.bookId));
    final navigate = ref.read(
      bookSearchNavigationProvider(widget.bookId).notifier,
    );
    final colors = context.gtColors;
    final status =
        state.error ??
        (state.busy
            ? '${state.complete ? '已显示 ${state.hits.length} 处，' : ''}正在搜索'
                  '${state.total > 0 ? '（已查 ${state.scanned}/${state.total} 章）' : '…'}'
            : state.cancelled
            ? '查询已取消，已显示结果保留'
            : state.complete
            ? '已显示 ${state.hits.length} 处${state.next == null ? '（全部结果）' : '，还有更多'}'
            : state.query.trim().isEmpty
            ? ''
            : '点击搜索开始查询');
    return Scaffold(
      key: const ValueKey('book-search-page'),
      backgroundColor: ReaderSheet.backgroundOf(context),
      appBar: GtAppBar(
        backgroundColor: ReaderSheet.backgroundOf(context),
        foregroundColor: colors.textPrimary,
        elevation: 0,
        title: Text('全文搜索', style: GtText.sectionTitle(colors.textPrimary)),
        leading: GtButton.icon(
          tooltip: '返回',
          icon: const BackButtonIcon(),
          onPressed: () {
            vm.close();
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
        ),
      ),
      bottomNavigationBar: navigation.origin == null
          ? null
          : SafeArea(
              top: false,
              child: GtButton(
                onPressed: navigation.busy
                    ? null
                    : () async {
                        FocusManager.instance.primaryFocus?.unfocus();
                        await navigate.returnToOrigin();
                      },
                child: const Text('回到搜索前位置'),
              ),
            ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
              child: TextField(
                key: const ValueKey('book-search-input'),
                controller: _input,
                style: GtText.body(colors.textPrimary),
                textInputAction: TextInputAction.search,
                onChanged: vm.setQuery,
                onSubmitted: (_) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  if (!state.busy) vm.search();
                },
                decoration: InputDecoration(
                  labelText: '搜索本书正文',
                  labelStyle: GtText.caption(colors.textSecondary),
                  suffixIcon: GtButton(
                    onPressed: state.busy
                        ? vm.cancelQuery
                        : state.query.trim().isEmpty
                        ? null
                        : () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            vm.search();
                          },
                    child: Text(state.busy ? '取消' : '搜索'),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
              child: SizedBox(
                height: MediaQuery.textScalerOf(context).scale(11) * 2.8,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    state.hits.isNotEmpty &&
                            (!state.complete ||
                                state.resultQuery != state.query.trim())
                        ? '$status；以下仍是“${state.resultQuery}”的上次结果'
                        : status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GtText.caption(
                      state.error == null
                          ? colors.textSecondary
                          : colors.danger,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              // 与目录共用补发触点过滤，拉伸和裁剪只作用于结果区域。
              child: ContentsScrollArea(
                child: !state.busy && state.complete && state.hits.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(GtSpacing.s5),
                        child: Text(
                          '本书没有匹配结果，请试试更短的词。',
                          style: GtText.body(colors.textPrimary),
                        ),
                      )
                    : ListView.builder(
                        key: PageStorageKey(
                          'search-${widget.bookId}-${state.resultQuery}',
                        ),
                        itemCount:
                            state.hits.length + (state.next == null ? 0 : 1),
                        itemBuilder: (context, i) {
                          if (i == state.hits.length) {
                            return GtButton(
                              onPressed:
                                  state.busy ||
                                      state.resultQuery != state.query.trim()
                                  ? null
                                  : () => vm.search(more: true),
                              child: const Text('加载更多'),
                            );
                          }
                          final hit = state.hits[i];
                          return Material(
                            color: ReaderSheet.backgroundOf(context),
                            child: GtListButton(
                              key: ValueKey('book-search-hit-$i'),
                              onPressed: navigation.busy || !state.complete
                                  ? null
                                  : () async {
                                      FocusManager.instance.primaryFocus
                                          ?.unfocus();
                                      await navigate.pick(hit);
                                    },
                              title: Text(
                                hit.chapterTitle.isEmpty
                                    ? '正文'
                                    : hit.chapterTitle,
                                style: GtText.caption(colors.textSecondary),
                              ),
                              subtitle: Text.rich(
                                textAlign: TextAlign.justify,
                                TextSpan(
                                  style: GtText.body(colors.textPrimary),
                                  children: [
                                    TextSpan(
                                      text: hit.context.substring(
                                        0,
                                        hit.matchStart,
                                      ),
                                    ),
                                    TextSpan(
                                      text: hit.context.substring(
                                        hit.matchStart,
                                        hit.matchEnd,
                                      ),
                                      style: TextStyle(
                                        color: colors.actionPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    TextSpan(
                                      text: hit.context.substring(hit.matchEnd),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
