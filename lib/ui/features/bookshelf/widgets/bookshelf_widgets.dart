import '../../../../app/di/book_group_providers.dart';
import 'dart:typed_data';

import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/decorations.dart';
import '../view_models/bookshelf_view_model.dart';
import '../../../core/widgets/gt_icon.dart';
import '../../../../domain/models/book.dart';
import 'invalid_book_dialog.dart';

/// 书架网格条目：封面 + 角标 + 书名 + 作者。
///
/// 交互约定：
/// - 长按进入多选模式并选中这一本；
/// - 多选模式下点击切换选中状态，不再进入阅读页；
/// - 选中时封面压一层暗色并显示勾选圆点。
///
/// 排版约定：
/// - 书名最多两行（「书名 + 副标题」这类长书名一行放不下），作者一行，超出省略；
/// - 文字区占固定高度（按当前系统字号换算），封面用 Expanded 吃掉剩余高度，
///   所以系统字号或字体行高有差异时只会让封面略微变矮，不会出现像素溢出；
/// - 书名固定占两行的高度：短书名第二行留空，这样同一行里封面仍然完全等大。
class BookTile extends ConsumerWidget {
  const BookTile({super.key, required this.book, this.coverOverlay, this.onTapOverride, this.coverBytes});
  final Uint8List? coverBytes;
  final Widget? coverOverlay;
  final VoidCallback? onTapOverride;

  final Book book;

  /// 书名/作者字号与行高常量（网格比例计算复用同一套值）
  static const double titleFontSize = 11.5;
  static const double titleLineHeight = 1.35;
  static const double authorFontSize = 10.5;
  static const double authorLineHeight = 1.35;

  /// 书名最多显示的行数
  static const int titleMaxLines = 2;

  /// 单行行盒高度。
  ///
  /// 向上取整：引擎给出的行高是整数（例如 11.5 × 1.35 = 15.525 → 16），
  /// 按小数乘出来会少零点几像素，用在固定高度的区域里就会被判定溢出。
  static double _lineBox(
    double fontSize,
    double lineHeight,
    TextScaler scaler,
  ) => (scaler.scale(fontSize) * lineHeight).ceilToDouble();

  /// 书名区固定高度：按最大行数留位置，跟随系统字号缩放。
  static double titleBlockHeight(TextScaler scaler) =>
      _lineBox(titleFontSize, titleLineHeight, scaler) * titleMaxLines;

  /// 文字区目标高度：书名两行 + 作者一行，跟随系统字号缩放。
  static double textBlockHeight(TextScaler scaler) =>
      titleBlockHeight(scaler) +
      GtSpacing.s1 +
      _lineBox(authorFontSize, authorLineHeight, scaler);

  /// 书名实际占用的高度：用与渲染同一套参数量一次。
  ///
  /// 短书名占一行、长书名占两行，量出来的高度决定书名区的高度；剩下的余量
  /// 留到格子底部，这样同一行里封面尺寸仍然完全等大。
  static double measureTitleHeight({
    required String title,
    required TextStyle style,
    required TextScaler scaler,
    required double maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: title, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: titleMaxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// 条目内容高度：封面（宽高比见 GtSize.coverAspectRatio）+ 间距 + 文字区。
  /// 网格比例与条目自身用同一个公式，保证封面在同一行里完全等大。
  static double contentHeightFor(double width, TextScaler scaler) =>
      width / GtSize.coverAspectRatio + GtSpacing.s2 + textBlockHeight(scaler);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final coverFile = ref.watch(bookCoverFileProvider)(book);
    final shelf = ref.watch(bookshelfProvider);
    final selecting = shelf.selectionMode;
    final selected = shelf.selectedIds.contains(book.id);
    // 角标配色：进度=蓝、已读=绿、未读=浅灰
    final (flagBg, flagFg) = book.finished
        ? (GtPalette.completed, GtColors.light.onPrimary)
        : book.readProgress == null
        ? (colors.subtle, colors.textSecondary)
        : (colors.actionPrimary, colors.onPrimary);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final scaler = MediaQuery.textScalerOf(context);
        final titleStyle = GtText.bookTitle(
          selected ? colors.actionPrimary : colors.textPrimary,
          family: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        ).copyWith(fontSize: titleFontSize, height: titleLineHeight);
        // 书名实际占几行就占多高，余下的高度留到格子底部
        final titleHeight = measureTitleHeight(
          title: book.title,
          style: titleStyle,
          scaler: scaler,
          maxWidth: w,
        );
        final titleSlack = titleBlockHeight(scaler) - titleHeight;
        return GtButton.raw(
          borderRadius: BorderRadius.circular(GtRadius.control),
          onPressed: onTapOverride ?? () => selecting
              ? ref.read(bookshelfProvider.notifier).toggleSelection(book.id)
              : openShelfBook(context, ref, book),
          onLongPress: coverOverlay != null ? null : () =>
              ref.read(bookshelfProvider.notifier).beginSelection(book.id),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面吃掉文字区之外的剩余高度：格子高度一致，行内封面等大
              Expanded(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 多选模式下用勾选圆点替代进度角标，避免两套标记叠在一起
                    if (!selecting && coverOverlay == null)
                      Positioned(
                        top: -CoverFlag.flagHeight,
                        left: w * 0.65,
                        child: FractionalTranslation(
                          translation: const Offset(-0.5, 0),
                          child: CoverFlag(
                            label: book.flagLabel,
                            background: flagBg,
                            foreground: flagFg,
                          ),
                        ),
                      ),
                    // 封面后画，标签底沿不覆盖书本（含分数像素边缘）。
                    Positioned.fill(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          BookCover(
                            bookId: book.id,
                            title: book.title,
                            author: book.author,
                            imagePath: coverFile,
                            imageBytes: coverBytes,
                          ),
                          ?coverOverlay,
                          if (book.status == BookStatus.contentMissing)
                            const InvalidBookOverlay(),
                          if (selected && coverOverlay == null)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.scrim.withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(
                                  GtRadius.cover,
                                ),
                                border: Border.all(
                                  color: colors.actionPrimary,
                                  width: 2,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (selecting && coverOverlay == null)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: _SelectionDot(selected: selected),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: GtSpacing.s2),
              // 书名最多两行，作者紧跟在书名下面；书名区不足两行的余量补到
              // 格子底部，这样同一行里封面尺寸仍然完全等大。
              SizedBox(
                height: titleHeight,
                child: Text(
                  book.title,
                  maxLines: titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              const SizedBox(height: GtSpacing.s1),
              Text(
                book.author.isEmpty ? '未知作者' : book.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GtText.caption(
                  colors.textMuted,
                ).copyWith(fontSize: authorFontSize, height: authorLineHeight),
              ),
              // 短书名的富余高度：留在底部，保证封面等大
              if (titleSlack > 0) SizedBox(height: titleSlack),
            ],
          ),
        );
      },
    );
  }
}

/// 多选模式下的勾选圆点。
class _SelectionDot extends StatelessWidget {
  const _SelectionDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        // 未选中用半透明白：在深色封面上不会变成一块白斑
        color: selected
            ? colors.actionPrimary
            : Colors.white.withValues(alpha: 0.35),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? colors.actionPrimary : colors.borderControl,
          width: 1.5,
        ),
      ),
      // Center 让图标保持自身尺寸，不被圆点的紧约束放大
      child: selected
          ? Center(
              child: GtIcon(GtIcons.check, size: 13, color: colors.onPrimary),
            )
          : null,
    );
  }
}

/// 横向展示分类与分组；排序与布局放在标题栏的更多菜单。
class ShelfFilterBar extends ConsumerWidget {
  const ShelfFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final state = ref.watch(bookshelfProvider);
    final vm = ref.read(bookshelfProvider.notifier);

    const tabs = <MapEntry<ShelfFilter, String>>[
      MapEntry(ShelfFilter.all, '全部'),
      MapEntry(ShelfFilter.reading, '在读'),
      MapEntry(ShelfFilter.finished, '已读'),
      MapEntry(ShelfFilter.ungrouped, '未分组'),
    ];

    final groups = ref.watch(bookGroupsProvider).value ?? const [];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: GtSize.shelfPagePadding),
      child: SingleChildScrollView(
        key: const ValueKey('shelf-filter-scroll'),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tab in tabs) ...[
              _FilterTab(
                key: ValueKey('shelf-tab-${tab.value}'),
                label: tab.value,
                selected: state.groupId == null && state.filter == tab.key,
                onTap: () => vm.setFilter(tab.key),
              ),
              if (tab != tabs.last || groups.isNotEmpty)
                _tabDivider(colors),
            ],
            for (final group in groups) ...[
              _FilterTab(
                key: ValueKey('shelf-group-${group.id}'),
                label: group.name,
                selected: state.groupId == group.id,
                onTap: () => vm.setGroup(group.id),
              ),
              if (group != groups.last) _tabDivider(colors),
            ],
          ],
        ),
      ),
    );
  }
}

Widget _tabDivider(GtColors colors) => Container(
  width: 1,
  height: 12,
  margin: const EdgeInsets.symmetric(horizontal: GtSpacing.s1),
  color: colors.borderSubtle,
);

class _FilterTab extends StatelessWidget {
  const _FilterTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final color = selected ? colors.actionPrimary : colors.textSecondary;
    return GtButton.raw(
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: GtSpacing.s1,
              horizontal: 1,
            ),
            child: Text(
              label,
              style: GtText.body(
                color,
                weight: FontWeight.w500,
              ).copyWith(fontSize: 13),
            ),
          ),
          Container(
            width: 24,
            height: 2.5,
            decoration: BoxDecoration(
              color: selected ? colors.actionPrimary : Colors.transparent,
              borderRadius: BorderRadius.circular(GtRadius.pill),
            ),
          ),
        ],
      ),
    );
  }
}
