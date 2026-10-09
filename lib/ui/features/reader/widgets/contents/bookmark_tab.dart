import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/di/app_providers.dart';
import '../../../../../domain/models/bookmark.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/theme/reading_theme.dart';
import '../../../../core/widgets/gt_icon.dart';
import '../../../../core/widgets/gt_dialog_action.dart';
import '../../../../core/widgets/state_views.dart';
import '../../view_models/reader_session_view_model.dart';
import '../../view_models/reader_progress_return.dart';
import '../../view_models/reader_view_model.dart';
import '../../view_models/original_layout_controller.dart';
import 'note_tab.dart';

/// 书签页签：按摘录或章节名搜索，可跳回原位置或删除。
class BookmarkTab extends ConsumerWidget {
  const BookmarkTab({super.key, required this.bookId, required this.query});

  final String bookId;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarks = ref.watch(bookmarksProvider(bookId)).value ?? const [];
    final session = ref.watch(readerSessionProvider(bookId)).value;
    final notifier = ref.read(readerSessionProvider(bookId).notifier);
    final searchQuery = query.trim();
    final visible = [
      for (final bookmark in bookmarks)
        if (searchQuery.isEmpty || _matches(bookmark, session, searchQuery))
          bookmark,
    ];

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
            location: _chapterTitleOf(session, bookmark),
            onJump: () async {
              final vm = ref.read(readerProvider.notifier);
              final hold = notifier.layoutMode.isOriginal
                  ? ref
                        .read(originalLayoutProvider(bookId))
                        .value
                        ?.holdPageDuringJump
                  : null;
              Future<void> jump() async {
                vm.closePanel(collapseControls: true);
                if (hold != null) {
                  await hold(() => notifier.goToLocator(bookmark.locator));
                } else {
                  await notifier.goToLocator(bookmark.locator);
                }
              }

              try {
                // 先遮住正文再收起面板；原书撤下临时截图后，正文才开始淡化。
                await ref
                    .read(readerProgressReturnProvider(bookId).notifier)
                    .jump(jump);
              } catch (_) {
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
    } catch (_) {
      vm.showNotice('书签没有删除成功，请重试');
    }
  }

  bool _matches(Bookmark bookmark, ReaderSession? session, String query) =>
      bookmark.quote.contains(query) ||
      _chapterTitleOf(session, bookmark).contains(query);

  String _chapterTitleOf(ReaderSession? session, Bookmark bookmark) {
    if (session == null) return '';
    for (final chapter in session.chapters) {
      if (chapter.id == bookmark.locator.chapterId) return chapter.title;
    }
    return '';
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
