part of '../views/reader_view.dart';

/// 控制层底部块（参考图 03）：
/// 上一章/下一章 → 进度滑块 → 工具栏（目录/亮度/字体/听书/自动阅读）。
class _BottomControls extends ConsumerStatefulWidget {
  const _BottomControls({
    super.key,
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
  ConsumerState<_BottomControls> createState() => _BottomControlsState();
}

class _BottomControlsState extends ConsumerState<_BottomControls> {
  Timer? _progressTimer;
  bool _showProgress = true;

  @override
  void initState() {
    super.initState();
    _showProgress = widget.state.panel == ReaderPanel.none;
  }

  @override
  void didUpdateWidget(_BottomControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.panel == widget.state.panel) return;
    _progressTimer?.cancel();
    if (widget.state.panel != ReaderPanel.none) {
      _showProgress = false;
    } else if (MediaQuery.disableAnimationsOf(context)) {
      _showProgress = true;
    } else {
      // 主面板完全落回工具栏之后，再恢复上一章、进度和章名，避免相互穿过。
      _progressTimer = Timer(readerPanelExitDuration, () {
        if (mounted) setState(() => _showProgress = true);
      });
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  double? _dragProgress;
  ReaderSession? _lastPositionedSession;
  int _seekVersion = 0;
  bool _openingPanel = false;

  /// 选项与列表先准备，再一次显示面板，避免打开后空态变列表。
  Future<void> _openPanel(ReaderPanel panel) async {
    if (_openingPanel) return;
    _openingPanel = true;
    try {
      await prepareReaderPanel(
        context,
        ProviderScope.containerOf(context),
        widget.bookId,
        panel,
      );
      if (mounted) ref.read(readerProvider.notifier).openPanel(panel);
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '打开阅读面板失败');
      if (mounted) ref.read(readerProvider.notifier).showNotice('面板准备失败，请重试');
    } finally {
      _openingPanel = false;
    }
  }

  /// 换章请求还在路上：连点两次「下一章」不应该跳两章
  bool _chapterNavPending = false;

  /// 上一次按「上一章 / 下一章」落到的目录条目序号。
  ///
  /// 目录条目的进度是「章内字数」口径，而原书模式的上报位置是版面比例口径，
  /// 两者天然差 0.1%–0.4%（字数里每块带一个分隔符，版面没有）：靠位置反推
  /// 「现在在哪一条」会偶尔退回上一条，表现就是点一次跳过去、再点不动。
  /// 落点是按钮自己定的，记下来最稳；阅读位置改变后不再使用这次记录。
  int? _lastNavEntry;
  Locator? _lastNavPosition;

  // 一页可包含多个目录标题，刚跳到哪一项就从哪一项继续。
  // 真正翻页或从其它入口跳转后，旧条目不再压住新的阅读位置。
  int? _rememberedEntry(ReaderSession? session) =>
      _chapterNavPending ||
          (_lastNavPosition != null &&
              session?.currentAnchor?.samePosition(_lastNavPosition!) == true)
      ? _lastNavEntry
      : null;

  /// 上一章 / 下一章按**目录条目**走。
  ///
  /// 一个 XHTML 里可能装着一百章（NCX 的多个锚点指向同一个章节文件），
  /// 按章节文件走会一步跨过整本正文：点「下一章」走到这本书的正文文件后就没得
  /// 走了，看起来像点不动。这里用滑块下方章名同一份目录索引，取当前位置的
  /// 下一条/上一条：章内条目交给目录跳转（原书模式用锚点），跨出本章才换章。
  Future<void> _goToAdjacentChapter(int delta) async {
    if (_chapterNavPending) return;
    final service = ref.read(listeningServiceProvider);
    final speech = service.snapshot;
    if (speech.bookId == widget.bookId &&
        speech.hasSession &&
        speech.followReading) {
      _chapterNavPending = true;
      try {
        await ref
            .read(readerProgressReturnProvider(widget.bookId).notifier)
            .transition(
              () => ref
                  .read(listeningPanelProvider(widget.bookId))
                  .chapter(delta),
            );
      } finally {
        _chapterNavPending = false;
      }
      return;
    }
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    if (session == null) return;
    final remembered = _rememberedEntry(session);
    _chapterNavPending = true;
    try {
      final entries = await ref.read(
        progressTitlesProvider(widget.bookId).future,
      );
      if (!mounted || entries.isEmpty) return;
      // 当前位置对应的条目：用内容文本位置比（与目录索引同一口径）
      final current = tocEntryIndexAt(
        entries,
        position: session.contentProgress,
        chapterId: session.chapter.id,
        remembered: remembered,
      );
      final next = current + delta;
      if (next < 0 || next >= entries.length) {
        ref
            .read(readerProvider.notifier)
            .showNotice(delta > 0 ? '已经是最后一章了' : '已经是第一章了');
        return;
      }
      final entry = entries[next];
      if (const bool.fromEnvironment('GT_TRACE_CHAPTER_NAV')) {
        debugPrint(
          'CHAPTER_NAV current=$current remembered=$remembered '
          'position=${session.contentProgress} target=$next '
          'title=${entry.title} anchor=${entry.anchorId} progress=${entry.progress}',
        );
      }
      final previousEntry = _lastNavEntry;
      _lastNavEntry = next;
      try {
        final notifier = ref.read(
          readerSessionProvider(widget.bookId).notifier,
        );
        Future<void> jump() async {
          await notifier.goToChapterFromToc(
            entry.chapterId,
            title: entry.title,
            anchorId: entry.anchorId,
            rememberReturn: false,
          );
          await notifier.waitForTocPosition();
        }

        final hold = notifier.usesOriginalWebView && !session.scrolling
            ? ref
                  .read(originalLayoutProvider(widget.bookId))
                  .value
                  ?.holdPageDuringJump
            : null;
        await ref
            .read(readerProgressReturnProvider(widget.bookId).notifier)
            .transition(() async {
              if (hold == null) {
                await jump();
              } else {
                await hold(jump);
              }
            });
        _lastNavPosition = ref
            .read(readerSessionProvider(widget.bookId))
            .value
            ?.currentAnchor;
      } catch (_) {
        _lastNavEntry = previousEntry;
        rethrow;
      }
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '切换章节失败');
      if (mounted) {
        ref.read(readerProvider.notifier).showNotice('换章未完成，请重试');
      }
    } finally {
      _chapterNavPending = false;
    }
  }

  /// 落点没变化时显示按钮刚选中的条目，否则按当前内容位置查询。
  int _titleIndex(
    List<TocProgressEntry> entries,
    double position, {
    String? chapterId,
  }) => tocEntryIndexAt(
    entries,
    position: position,
    chapterId: chapterId,
    remembered: chapterId == null
        ? null
        : _rememberedEntry(
            ref.read(readerSessionProvider(widget.bookId)).value,
          ),
  );

  Future<void> _seek(double value) async {
    final version = ++_seekVersion;
    // 直接记录真实滑块提交，不用自动化入口的耗时替代用户操作。
    final current = readerWorkTraceEnabled
        ? ref.read(readerSessionProvider(widget.bookId)).value
        : null;
    final settings = readerWorkTraceEnabled
        ? ref.read(readerSettingsProvider(widget.bookId)).value?.settings
        : null;
    final trace = !readerWorkTraceEnabled
        ? null
        : ReaderWorkTrace.start('reader.progress.user', {
            'bookId': widget.bookId,
            'request': version,
            'target': value,
            'fromChapter': current?.chapterIndex,
            'fromProgress': current?.bookProgress,
            'scrolling': current?.scrolling,
            'fontFamily': settings?.fontFamily,
            'originalFont': settings?.useOriginalFont,
            'fontSize': settings?.fontSize,
            'fontWeight': settings?.fontWeight,
            'lineHeight': settings?.lineHeight,
            'paragraphGap': settings?.paragraphGapEm,
          });
    var status = 'ok';
    try {
      final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
      final hold =
          notifier.usesOriginalWebView &&
              ref.read(readerSessionProvider(widget.bookId)).value?.scrolling !=
                  true
          ? ref
                .read(originalLayoutProvider(widget.bookId))
                .value
                ?.holdPageDuringJump
          : null;
      Future<void> jump() async {
        if (!mounted || version != _seekVersion) return;
        _lastNavEntry = null;
        await notifier.goToProgress(value, waitForOriginal: true);
      }

      await ref.read(readerProgressReturnProvider(widget.bookId).notifier).seek(
        () async {
          if (hold == null) {
            await jump();
          } else {
            await hold(jump);
          }
        },
      );
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '跳转进度失败');
      status = 'error';
      if (mounted && version == _seekVersion) {
        ref.read(readerProvider.notifier).showNotice('进度跳转未完成，请重试');
      }
    } finally {
      if (mounted && version == _seekVersion) {
        setState(() => _dragProgress = null);
      }
      trace?.finish(status: version == _seekVersion ? status : 'superseded');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final bookId = widget.bookId;
    final returnState = ref.watch(readerProgressReturnProvider(bookId));
    final dividerColor = theme.secondary.withValues(alpha: 0.18);
    final current = ref.watch(readerSessionProvider(bookId)).value;
    final original = ref
        .read(readerSessionProvider(bookId).notifier)
        .layoutMode
        .isOriginal;
    // 换章会先清空原书位置；目标页回报前沿用已显示的位置，不能把等待当成 0%。
    final positioned =
        current != null &&
        (current.scrolling
            ? current.isReady
            : original
            ? current.isOriginal
            : current.isReady &&
                  current.layout?.chapterId == current.chapter.id);
    if (positioned) _lastPositionedSession = current;
    final session = positioned ? current : _lastPositionedSession ?? current;
    // 拖动值只用于面板反馈，不等待分页/位置回报，也不连续重载正文。
    final progress = _dragProgress ?? session?.readingProgress ?? 0;
    // 章名查询与换章同一口径：拖动时用滑块值（它就是要落到的位置），
    // 其余用内容文本位置
    final position = _dragProgress ?? session?.contentProgress ?? 0;
    final titles = ref.watch(progressTitlesProvider(bookId));
    final entries = titles.value;
    final title = entries == null || entries.isEmpty
        ? session?.chapter.title ?? ''
        : entries[_titleIndex(
                entries,
                position,
                chapterId: _dragProgress == null ? session?.chapter.id : null,
              )]
              .title;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: ReaderControlsEntrance(
        visible: widget.visible,
        top: false,
        child: SafeArea(
          top: false,
          maintainBottomViewPadding: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showProgress &&
                  returnState.fromSlider &&
                  returnState.origin != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ProgressReturnButton(
                    colors: theme.controlsColors,
                    busy: returnState.busy,
                    onPressed: () => ref
                        .read(readerProgressReturnProvider(bookId).notifier)
                        .returnToOrigin(),
                  ),
                ),
              Container(
                color: theme.background,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ProgressReveal(
                      reducedMotion: MediaQuery.disableAnimationsOf(context),
                      alignment: Alignment.bottomCenter,
                      child: !_showProgress
                          ? const SizedBox(width: double.infinity)
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 正文与控制条之间的分隔线（参考图 03）
                                Container(height: 1, color: dividerColor),
                                SizedBox(
                                  height: 44,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        _ChapterNavButton(
                                          label: '上一章',
                                          icon: GtIcons.chevronLeft,
                                          color: theme,
                                          onTap: () => unawaited(
                                            _goToAdjacentChapter(-1),
                                          ),
                                        ),
                                        const Spacer(),
                                        _ChapterNavButton(
                                          label: '下一章',
                                          icon: GtIcons.chevronRight,
                                          color: theme,
                                          onTap: () => unawaited(
                                            _goToAdjacentChapter(1),
                                          ),
                                          iconFirst: false,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: SettingsSlider(
                                    trackThickness:
                                        GtSliderSize.trackThicknessSmall,
                                    thumbRadius: GtSliderSize.thumbRadiusSmall,
                                    label: '',
                                    compact: true,
                                    showNumber: false,
                                    disableWhileSaving: false,
                                    backgroundColor: theme.background,
                                    value: progress.clamp(0.0, 1.0),
                                    min: 0,
                                    max: 1,
                                    divisions: 10000,
                                    format: (v) =>
                                        '${(v * 100).toStringAsFixed(2)}%',
                                    onPreview: (v) {
                                      if (v != null) {
                                        ref
                                            .read(
                                              readerProgressReturnProvider(
                                                bookId,
                                              ).notifier,
                                            )
                                            .beginSlider();
                                        setState(() {
                                          _seekVersion++;
                                          _dragProgress = v;
                                        });
                                      }
                                    },
                                    save: session == null || titles.isLoading
                                        ? null
                                        : _seek,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: GtText.caption(
                                            theme.secondary,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        '${(progress * 100).toStringAsFixed(2)}%',
                                        style: GtText.caption(theme.secondary),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: GtSpacing.s3),
                              ],
                            ),
                    ),
                    ReaderToolbar(
                      showListening: !ref.watch(pdfModeProvider(bookId)),
                      theme: theme,
                      onSelect: (panel) => unawaited(_openPanel(panel)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 减少动态效果时直接换高度，避免零时长 AnimatedSize 在布局期间重入。
class _ProgressReveal extends StatelessWidget {
  const _ProgressReveal({
    required this.reducedMotion,
    required this.alignment,
    required this.child,
  });
  final bool reducedMotion;
  final AlignmentGeometry alignment;
  final Widget child;
  @override
  Widget build(BuildContext context) => reducedMotion
      ? child
      : AnimatedSize(
          duration: readerProgressCollapseDuration,
          alignment: alignment,
          child: child,
        );
}

/// 上一章 / 下一章 按钮。
class _ChapterNavButton extends StatelessWidget {
  const _ChapterNavButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.color,
    this.iconFirst = true,
  });

  final String label;
  final String icon;
  final VoidCallback onTap;
  final ReadingTheme color;
  final bool iconFirst;

  @override
  Widget build(BuildContext context) {
    return GtButton.raw(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(GtRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: GtSpacing.s2,
          vertical: GtSpacing.s2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconFirst) ...[
              GtIcon(icon, size: 18, color: color.secondary),
              const SizedBox(width: GtSpacing.s1),
            ],
            Text(
              label,
              style: GtText.caption(color.secondary).copyWith(fontSize: 13),
            ),
            if (!iconFirst) ...[
              const SizedBox(width: GtSpacing.s1),
              GtIcon(icon, size: 18, color: color.secondary),
            ],
          ],
        ),
      ),
    );
  }
}
