import '../../../../app/di/book_group_providers.dart';
import '../widgets/shelf_selection_bar.dart';

import 'dart:math' as math;

import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../../domain/models/import_job.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/router/app_router.dart';
import '../../../../platform/channels/original_webview_warmup.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/gt_icon.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/frame_fade.dart';
import '../../../../domain/models/book.dart';
import '../widgets/invalid_book_dialog.dart';
import '../view_models/bookshelf_view_model.dart';
import '../view_models/visible_shelf_books.dart';
import '../view_models/shelf_sort_controller.dart';
import '../widgets/bookshelf_widgets.dart';
import '../widgets/shelf_header.dart';
import '../widgets/shelf_scroll_area.dart';
import '../../import/widgets/shelf_import_tile.dart';

/// 书架页（参考图 01）：
/// 标题栏（品牌名 + 搜索／导入／更多）→ 可展开搜索 → 筛选 → 书籍。
///
/// 长按书籍进入多选模式，可多选后一次删除（设计文档 2.1「书籍管理」）。
/// 书籍来自数据库流；数据未就绪时显示稳定加载态，不先闪一个空书架。
class BookshelfView extends ConsumerWidget {
  const BookshelfView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final shelf = ref.watch(bookshelfProvider);
    final library = ref.watch(libraryBooksProvider);
    final visible = ref.watch(visibleShelfBooksProvider);
    final groups = ref.watch(bookGroupsProvider);
    final sort = ref.watch(shelfSortProvider);
    if (!sort.hasValue) {
      return Scaffold(
        body: sort.hasError
            ? GtErrorView(
                title: '排序设置读取失败',
                message: '${sort.error}',
                onRetry: () => ref.invalidate(shelfSortProvider),
              )
            : const GtLoadingView(label: '正在整理书架…'),
      );
    }
    // 分类和书籍一起就绪，避免先出现四个默认分类、随后再补分组。
    if (!groups.hasValue) {
      return Scaffold(
        body: groups.hasError
            ? GtErrorView(
                title: '分组读取失败',
                message: '${groups.error}',
                onRetry: () => ref.invalidate(bookGroupsProvider),
              )
            : const GtLoadingView(label: '正在整理书架…'),
      );
    }

    final route = ModalRoute.of(context);
    if (route?.isCurrent != false &&
        library.value?.any((book) => book.format.usesOriginalWebView) == true) {
      OriginalWebViewWarmup.schedule(
        allowed: () => context.mounted && (route?.isCurrent ?? true),
      );
    }
    // 普通标题和多选工具栏共用行高；多选工具栏仍需 48dp 内容区，
    // 顶部三个普通按钮缩至 36dp，进入多选也不推移搜索框。
    final scaler = MediaQuery.textScalerOf(context);
    final headerHeight =
        GtSpacing.s4 +
        math.max(
          48.0,
          math.max(
            scaler.scale(24) * 1.25,
            scaler.scale(15) * 1.5 + GtSpacing.s2 * 2,
          ),
        );
    return PopScope(
      // 多选模式下按返回键先退出多选，不直接退出应用
      canPop: !shelf.selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(bookshelfProvider.notifier).clearSelection();
      },
      child: Scaffold(
        bottomSheet: shelf.selectionMode ? const ShelfSelectionBar() : null,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShelfHeader(
                height: headerHeight,
                selectionHeader: shelf.selectionMode
                    ? _buildSelectionHeader(context, ref, colors)
                    : null,
              ),
              const SizedBox(height: GtSpacing.s2),
              const ShelfFilterBar(),
              Expanded(
                child: FrameFade(
                  revision: (
                    shelf.filter,
                    shelf.groupId,
                    shelf.sort,
                    shelf.gridView,
                  ),
                  child: visible.hasValue
                      ? _buildBody(
                          context,
                          ref,
                          visible.requireValue,
                          hasBooks: library.value?.isNotEmpty ?? false,
                          query: shelf.query.trim(),
                        )
                      : visible.hasError
                      ? GtErrorView(
                          title: '书架读取失败',
                          message: '${visible.error}',
                          onRetry: () => ref.invalidate(libraryBooksProvider),
                        )
                      : const GtLoadingView(label: '正在整理书架…'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionHeader(
    BuildContext context,
    WidgetRef ref,
    GtColors colors,
  ) {
    final shelf = ref.watch(bookshelfProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已选 ${shelf.selectedIds.length} 本',
              style: GtText.pageTitle(colors.textPrimary),
            ),
          ),
          GtButton(
            key: const ValueKey('shelf-exit-selection'),
            onPressed: ref.read(bookshelfProvider.notifier).clearSelection,
            child: Text('完成', style: GtText.body(colors.actionPrimary)),
          ),
        ],
      ),
    );
  }

  /// 有数据后按「空书架 / 搜索无结果 / 列表」三种情况展示。
  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    List<Book> books, {
    required bool hasBooks,
    required String query,
  }) {
    if (books.isNotEmpty || ref.watch(shelfImportItemsProvider).isNotEmpty) {
      return _buildGrid(context, ref, books);
    }
    // 书架本身为空与「搜索无结果」是两种不同状态
    if (!hasBooks && query.isEmpty) {
      return GtEmptyView(
        icon: GtIcons.folderPlus,
        title: '书架还是空的',
        message: '导入 EPUB 或 TXT，开始阅读吧',
        actionLabel: '导入书籍',
        onAction: () => context.push(AppRoutes.import),
      );
    }
    return GtEmptyView(
      icon: GtIcons.search,
      title: query.isEmpty ? '没有符合条件的书籍' : '没有找到「$query」',
      message: query.isEmpty ? '换个筛选条件试试' : '换个关键词试试',
    );
  }

  /// 自适应网格：列数 = max(1, floor((可用宽 + 间距) / (最小宽 + 间距)))。
  Widget _buildGrid(BuildContext context, WidgetRef ref, List<Book> books) {
    final imports = ref.watch(shelfImportItemsProvider);
    final ready = {
      for (final book in ref.watch(libraryBooksProvider).value ?? <Book>[])
        book.id: book,
    };
    final committingIds = imports.values.map((item) => item.bookId).toSet();
    books = [
      for (final entry in imports.entries)
        importPlaceholder(entry.key, entry.value),
      ...books.where((book) => !committingIds.contains(book.id)),
    ];
    // 批量导入结束前保留每本书的位置；完成项原位交给正式书籍。
    Widget tile(int index, bool list) {
      final book = books[index];
      final item = imports[book.id];
      final completed =
          item != null &&
              (item.stage == ImportStage.done ||
                  item.stage == ImportStage.duplicate) &&
              ready[item.bookId]?.status == BookStatus.active
          ? ready[item.bookId]
          : null;
      return KeyedSubtree(
        key: ValueKey(book.id),
        child: completed != null
            ? (list ? _ListRow(book: completed) : BookTile(book: completed))
            : item != null
            ? ShelfImportTile(book: book, item: item, listMode: list)
            : (list ? _ListRow(book: book) : BookTile(book: book)),
      );
    }

    final gridView = ref.watch(bookshelfProvider.select((s) => s.gridView));
    // extendBody 提供底栏加安全区的高度。只给滚动内容末尾留白，
    // 不缩短可视区域，书籍经过曲线凹口时仍能透出来。
    final bottomPadding = GtSpacing.s4 + MediaQuery.paddingOf(context).bottom;
    return ShelfScrollArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = GtSize.shelfColumnGap;
          // 网格自身左右有页边距，列数与单元宽度都按内容宽度计算
          final contentWidth =
              constraints.maxWidth - GtSize.shelfPagePadding * 2;
          final columns =
              ((contentWidth + gap) / (GtSize.shelfMinItemWidth + gap))
                  .floor()
                  .clamp(1, 6);
          final itemWidth = (contentWidth - gap * (columns - 1)) / columns;
          // 比例与 BookTile 的内容高度同源（含系统字号缩放），
          // 避免封面被拉伸压缩或文字溢出
          final aspectRatio =
              itemWidth /
              BookTile.contentHeightFor(
                itemWidth,
                MediaQuery.textScalerOf(context),
              );
          if (!gridView) {
            return ListView.separated(
              padding: EdgeInsets.fromLTRB(
                GtSize.shelfPagePadding,
                GtSpacing.s4,
                GtSize.shelfPagePadding,
                bottomPadding,
              ),
              itemCount: books.length,
              separatorBuilder: (_, _) => const SizedBox(height: GtSpacing.s3),
              itemBuilder: (context, index) => tile(index, true),
            );
          }
          return GridView.builder(
            // 分类下原有的 16dp 留白放进滚动区，供书本上滑时渐隐；
            // 另留 20dp 容纳封面顶部标签，静止时的书本位置保持一致。
            padding: EdgeInsets.fromLTRB(
              GtSize.shelfPagePadding,
              GtSpacing.s4 + 20,
              GtSize.shelfPagePadding,
              bottomPadding,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: GtSize.shelfRowGap,
              // 封面 2:3 + 书名两行 + 作者一行的精确比例
              childAspectRatio: aspectRatio,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) => tile(index, false),
          );
        },
      ),
    );
  }
}

/// 列表模式行（横向封面 + 信息）。
class _ListRow extends ConsumerWidget {
  const _ListRow({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final coverFile = ref.watch(bookCoverFileProvider)(book);
    final shelf = ref.watch(bookshelfProvider);
    final selecting = shelf.selectionMode;
    final selected = shelf.selectedIds.contains(book.id);
    final vm = ref.read(bookshelfProvider.notifier);
    return GtButton.raw(
      onPressed: () => selecting
          ? vm.toggleSelection(book.id)
          : openShelfBook(context, ref, book),
      onLongPress: () => vm.beginSelection(book.id),
      child: Row(
        children: [
          if (selecting) ...[
            GtIcon(
              selected ? GtIcons.checkCircle : GtIcons.circle,
              size: 20,
              color: selected ? colors.actionPrimary : colors.textMuted,
            ),
            const SizedBox(width: GtSpacing.s2),
          ],
          SizedBox(
            width: 56,
            child: Stack(
              children: [
                BookCover(
                  bookId: book.id,
                  format: book.format,
                  title: book.title,
                  author: book.author,
                  imagePath: coverFile,
                  preset: book.coverChoice?.preset,
                  showImageText: book.coverChoice?.imagePath != null,
                ),
                if (book.status == BookStatus.contentMissing)
                  const Positioned.fill(child: InvalidBookOverlay()),
              ],
            ),
          ),
          const SizedBox(width: GtSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 列表模式横向更宽，同样放宽到两行
                Text(
                  book.title,
                  maxLines: BookTile.titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: GtText.bookTitle(
                    selected ? colors.actionPrimary : colors.textPrimary,
                  ),
                ),
                const SizedBox(height: GtSpacing.s1),
                Text(
                  book.author.isEmpty
                      ? '${book.format.label} · ${book.chapterCount} 章'
                      : book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GtText.caption(colors.textMuted),
                ),
              ],
            ),
          ),
          Text(
            book.flagLabel,
            style: GtText.caption(
              book.finished
                  ? (Theme.of(context).brightness == Brightness.dark
                        ? GtPalette.completedDark
                        : GtPalette.completed)
                  : book.readProgress == null
                  ? colors.textMuted
                  : colors.actionPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
