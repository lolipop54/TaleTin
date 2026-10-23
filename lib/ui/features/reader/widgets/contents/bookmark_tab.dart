import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/di/app_providers.dart';
import '../../../../../core/diagnostics/bookmark_trace.dart';
import '../../../../../domain/models/bookmark.dart';
import '../../../../../domain/models/book_document.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/theme/reading_theme.dart';
import '../../../../core/widgets/gt_icon.dart';
import '../../../../core/widgets/gt_dialog_action.dart';
import '../../../../core/widgets/state_views.dart';
import '../../view_models/reader_session_view_model.dart';
import '../../view_models/annotation_list_provider.dart';
import '../../view_models/reader_progress_return.dart';
import '../../view_models/reader_view_model.dart';
import '../../view_models/original_layout_controller.dart';
import 'note_tab.dart';

/// 书签页签：按摘录或章节名搜索，可跳回原位置或删除。
class BookmarkTab extends ConsumerStatefulWidget {
  const BookmarkTab({super.key, required this.bookId, required this.query});

  final String bookId;
  final String query;

  @override
  ConsumerState<BookmarkTab> createState() => _BookmarkTabState();
}

class _BookmarkTabState extends ConsumerState<BookmarkTab> {
  String get bookId => widget.bookId;
  String get query => widget.query;
  BookmarkList? _shown;
  @override
  void didUpdateWidget(covariant BookmarkTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != bookId) _shown = null;
  }

  @override
  Widget build(BuildContext context) {
    final bookmarks = ref.watch(bookmarksProvider(bookId)).value;
    if (bookmarks == null) return const GtLoadingView(label: '正在读取书签…');
    final session = ref.watch(readerSessionProvider(bookId)).value;
    final notifier = ref.read(readerSessionProvider(bookId).notifier);
    final searchQuery = query.trim();
    final prepared = ref.watch(
      bookmarkListProvider((
        bookmarks,
        session?.chapters ?? const <Chapter>[],
        query,
      )),
    );
    if (prepared.hasValue) _shown = prepared.requireValue;
    if (_shown == null) return const GtLoadingView(label: '正在读取书签…');
    final visible = _shown!.bookmarks;

    if (visible.isEmpty) {
      return GtEmptyView(
        icon: GtIcons.bookmark,
        title: searchQuery.isEmpty ? '还没有书签' : '没有匹配的书签',
        message: searchQuery.isEmpty ? '阅读时点击顶部书签图标即可添加' : '换个关键词试试',
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s4),
      children: [
        for (final bookmark in visible)
          ReaderAnnotationItem(
            chipLabel: '书签',
            chipColor: kHighlightGray,
            date: _dateLabel(bookmark.createdAt),
            quote: bookmark.quote.isEmpty ? '（无摘录）' : bookmark.quote,
            quoteHighlight: null,
            quoteMaxLines: 3,
            location: _shown!.titles[bookmark.locator.chapterId] ?? '',
            onJump: () async {
              traceBookmark('jump-request', {
                'id': bookmark.id,
                'saved': bookmarkTraceLocator(bookmark.locator),
                'from': bookmarkTraceLocator(session?.currentAnchor),
                'fraction': session?.chapterProgress,
                'original': notifier.usesOriginalWebView,
                'scrolling': session?.scrolling,
              });
              final vm = ref.read(readerProvider.notifier);
              final hold = notifier.usesOriginalWebView
                  ? ref
                        .read(originalLayoutProvider(bookId))
                        .value
                        ?.holdPageDuringJump
                  : null;
              Future<void> jump() async {
                vm.closePanel(collapseControls: true);
                if (hold != null) {
                  await hold(() => notifier.goToBookmark(bookmark));
                } else {
                  await notifier.goToBookmark(bookmark);
                }
              }

              try {
                // 先遮住正文再收起面板；原书撤下临时截图后，正文才开始淡化。
                await ref
                    .read(readerProgressReturnProvider(bookId).notifier)
                    .jump(jump);
                // 面板此时已关闭，不再读取页面的ref；实际落点由会话上报日志记录。
                traceBookmark('jump-complete', {'id': bookmark.id});
              } catch (appError, appStack) {
                AppErrors.report(appError, appStack, operation: '跳转书签失败');
                traceBookmark('jump-failed', {'id': bookmark.id});
                vm.showNotice('定位失败，请重试');
              }
            },
            onDelete: () => _delete(context, ref, bookmark),
          ),
      ],
    );
  }

  /// 确认前不写库；取消、返回键和点遮罩都保留书签。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Bookmark bookmark,
  ) async {
    final repository = ref.read(annotationRepositoryProvider);
    final vm = ref.read(readerProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除书签？'),
        content: const Text('删除后无法恢复，阅读位置和笔记会保留。'),
        actions: [
          GtDialogAction(
            key: const Key('bookmark-delete-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            label: '取消',
          ),
          GtDialogAction(
            key: const Key('bookmark-delete-confirm'),
            role: GtDialogActionRole.danger,
            onPressed: () => Navigator.pop(dialogContext, true),
            label: '删除',
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await repository.removeBookmark(bookmark.id);
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '删除书签失败');
      vm.showNotice('书签没有删除成功，请重试');
    }
  }

  String _dateLabel(DateTime createdAt) {
    final local = createdAt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${local.month}月${local.day}日';
  }
}
