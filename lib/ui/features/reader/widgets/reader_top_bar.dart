part of '../views/reader_view.dart';

/// 控制层顶部栏：返回、书名、书签、搜索和更多。
class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.visible,
    required this.state,
    required this.theme,
    required this.bookId,
  });

  final bool visible;
  final ReaderState state;
  final ReadingTheme theme;
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(readerSessionProvider(bookId)).value;
    final anchor = session?.currentAnchor;
    final currentBookmark = ref.watch(currentBookmarkProvider(bookId));
    // 黑色轮廓映射为主题文字，白底映射为阅读底色；透明像素仍保持透明。
    // 用户替换成带白底的 PNG 时，不能用 srcIn 将整张图染成实心方块。
    List<double> tint(double paper, double ink) => [
      (paper - ink) * .2126,
      (paper - ink) * .7152,
      (paper - ink) * .0722,
      0,
      ink * 255,
    ];
    final iconTint = ColorFilter.matrix([
      ...tint(theme.background.r, theme.primary.r),
      ...tint(theme.background.g, theme.primary.g),
      ...tint(theme.background.b, theme.primary.b),
      0,
      0,
      0,
      1,
      0,
    ]);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ReaderControlsEntrance(
        top: true,
        visible: visible,
        child: SafeArea(
          top: ref.watch(readingControlsProvider).value?.statusBar ?? true,
          bottom: false,
          child: Container(
            color: theme.background,
            height: GtSize.appBarHeight,
            child: Row(
              children: [
                GtButton.icon(
                  onPressed: () async {
                    try {
                      await ref
                          .read(readingStatisticsServiceProvider)
                          .leaveVisual();
                      await ref
                          .read(automaticReadingProvider(bookId).notifier)
                          .pause();
                      await ref
                          .read(readerSessionProvider(bookId).notifier)
                          .flushPendingPosition();
                    } finally {
                      await ref
                          .read(readerSettingsProvider(bookId).notifier)
                          .pendingWrites;
                      if (context.mounted) {
                        await prepareShelfReturn(ref);
                        if (context.mounted) context.pop();
                      }
                    }
                  },
                  icon: GtIcon(
                    GtIcons.arrowBack,
                    size: 20,
                    color: theme.primary,
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      session?.book.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GtText.body(
                        theme.primary,
                        weight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                // 书签、搜索、已读三颗统一 36×36 触摸范围，不再各占 48×48。
                GtButton.icon(
                  style: GtButton.compactIconStyle,
                  onPressed: anchor == null
                      ? null
                      : () => toggleReaderBookmark(ref, bookId),
                  icon: GtIcon(
                    GtIcons.bookmark,
                    size: 24,
                    color: currentBookmark == null
                        ? theme.primary
                        : context.gtColors.actionPrimary,
                  ),
                ),
                GtButton.icon(
                  style: GtButton.compactIconStyle,
                  tooltip: '全文搜索',
                  onPressed: () async {
                    await ref
                        .read(bookSearchNavigationProvider(bookId).notifier)
                        .open();
                  },
                  icon: GtIcon(GtIcons.search, size: 24, color: theme.primary),
                ),
                GtButton.icon(
                  style: GtButton.compactIconStyle,
                  tooltip: '标记或撤销已读',
                  onPressed: () => confirmBookCompletion(context, ref, bookId),
                  icon: ColorFiltered(
                    colorFilter: iconTint,
                    child: Image.asset(
                      'assets/icons_used/已读.webp',
                      width: 36,
                      height: 36,
                      cacheWidth: (24 * MediaQuery.devicePixelRatioOf(context))
                          .ceil(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
