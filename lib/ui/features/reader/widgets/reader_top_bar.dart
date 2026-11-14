part of '../views/reader_view.dart';

/// 控制层顶部栏：返回、书名、书签、搜索和标记已读。
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
    final hasBookmark = ref.watch(currentBookmarkProvider(bookId)) != null;
    final bookFinished = ref.watch(
      bookCompletionsProvider.select(
        (records) =>
            records.value?.any(
              (record) => record.bookId == bookId && record.active,
            ) ??
            false,
      ),
    );
    // 每个开关只管自己那一侧：显示顶部状态栏时，状态栏所在的边留白；
    // 隐藏后那一边（含横屏同一侧的挖孔）一起归零，内容直接贴到屏幕边缘。
    final bars = ref.watch(readingControlsProvider).value;
    final showStatusBar = bars?.statusBar ?? true;
    final showNavigationBar = bars?.navigationBar ?? true;
    final window = ref.read(readingWindowProvider);
    return ValueListenableBuilder<ReadingBarInsets?>(
      valueListenable: window.barInsets,
      builder: (context, native, _) {
        final insets = readerControlInsets(
          context,
          native,
          statusBar: showStatusBar,
          navigationBar: showNavigationBar,
        );
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ReaderControlsEntrance(
            top: true,
            visible: visible,
            child: Padding(
              padding: EdgeInsets.only(
                left: insets.left,
                top: insets.top,
                right: insets.right,
              ),
              child: Container(
                key: const ValueKey('reader-top-bar-surface'),
                color: theme.background,
                height: GtSize.appBarHeight,
                child: Row(
                  children: [
                    GtButton.icon(
                      onPressed: () async {
                        final trace = ReaderWorkTrace.start(
                          'reader.exit.top_button',
                          {
                            'bookId': bookId,
                            'controls': state.controlsVisible,
                            'panel': state.panel.name,
                            'scrolling': session?.scrolling,
                            'layout': ref
                                .read(readerSettingsProvider(bookId))
                                .value
                                ?.settings
                                .layoutMode
                                .name,
                          },
                        );
                        var status = 'ok';
                        try {
                          // 只给原来的每次等待加起止日志，保留原有顺序和 finally。
                          try {
                            await traceReaderWork(
                              'reader.exit.top.statistics',
                              () => ref
                                  .read(readingStatisticsServiceProvider)
                                  .leaveVisual(),
                            );
                            await traceReaderWork(
                              'reader.exit.top.auto_pause',
                              () => ref
                                  .read(
                                    automaticReadingProvider(bookId).notifier,
                                  )
                                  .pause(),
                            );
                            await traceReaderWork(
                              'reader.exit.top.position',
                              () => ref
                                  .read(readerSessionProvider(bookId).notifier)
                                  .flushPendingPosition(),
                            );
                          } finally {
                            await traceReaderWork(
                              'reader.exit.top.settings',
                              () => ref
                                  .read(readerSettingsProvider(bookId).notifier)
                                  .pendingWrites,
                            );
                            if (context.mounted) {
                              await traceReaderWork(
                                'reader.exit.top.shelf',
                                () => prepareShelfReturnForExit(ref),
                              );
                              if (context.mounted) {
                                trace?.mark('route_pop_requested');
                                leaveReaderPage(context);
                                trace?.mark('route_pop_returned');
                              } else {
                                status = 'unmounted_before_pop';
                              }
                            } else {
                              status = 'unmounted_before_shelf';
                            }
                          }
                        } catch (error, appStack) {
                          AppErrors.report(
                            error,
                            appStack,
                            operation: '退出阅读失败',
                          );
                          status = error.runtimeType.toString();
                          rethrow;
                        } finally {
                          trace?.finish(status: status);
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
                    // 三个操作共用紧凑触摸范围与 24dp 图标。
                    GtButton.icon(
                      style: GtButton.compactIconStyle,
                      onPressed: anchor == null
                          ? null
                          : () => toggleReaderBookmark(ref, bookId),
                      icon: GtIcon(
                        hasBookmark ? GtIcons.bookmarkFilled : GtIcons.bookmark,
                        size: 24,
                        color: hasBookmark
                            ? bookmarkRibbonColor
                            : theme.primary,
                      ),
                    ),
                    if (!ref.watch(pdfModeProvider(bookId)))
                      GtButton.icon(
                        style: GtButton.compactIconStyle,
                        tooltip: '全文搜索',
                        onPressed: () async {
                          await ref
                              .read(
                                bookSearchNavigationProvider(bookId).notifier,
                              )
                              .open();
                        },
                        icon: GtIcon(
                          GtIcons.search,
                          size: 24,
                          color: theme.primary,
                        ),
                      ),
                    GtButton.icon(
                      style: GtButton.compactIconStyle,
                      tooltip: '标记或撤销已读',
                      onPressed: () =>
                          confirmBookCompletion(context, ref, bookId),
                      // SVG 的主题色只替换纸张和勾的绿色，保留勾周围的白边。
                      icon: bookFinished
                          ? SvgPicture.asset(
                              'assets/icons/document-check-filled.svg',
                              width: 24,
                              height: 24,
                              theme: const SvgTheme(
                                currentColor: GtPalette.completed,
                              ),
                            )
                          : GtIcon(
                              GtIcons.documentCheck,
                              size: 24,
                              color: theme.primary,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
