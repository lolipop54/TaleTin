part of 'original_reader_area.dart';

extension _OriginalChapterConfiguration on _OriginalReaderAreaState {
  /// 章节配置与回调；真正的文档由固定 iframe 保留。
  OriginalChapter _chapter({
    required int ordinal,
    required bool isNeighbor,
    required double? initialFraction,
    required double margin,
    required ReadingSettings settings,
  }) {
    final snapshot = widget.session;
    final controller = widget.controller;
    final bookId = widget.bookId;
    if (ReaderDeliveryExperiments.originalPriority &&
        ordinal == snapshot.chapterIndex &&
        snapshot.content != null) {
      final target =
          ref
              .read(readerSessionProvider(bookId).notifier)
              .peekOriginalExactPosition(ordinal) ??
          Locator(
            bookId: bookId,
            contentVersion: snapshot.book.contentVersion,
            chapterId: snapshot.chapter.id,
            blockId: '',
            utf16Offset: 0,
          );
      // 目标资源的位置映射与 WebView 装载并行；prepare 仍等待同一份完成结果。
      // 旧视觉续读同样需要完整内容对照表，不能等网页 ready 后才串行建立。
      // 不提前解析邻章，也不消耗精确目标或绕过来源检查。
      controller
          .positionMap(
            ordinal,
            snapshot.chapter.href ?? '',
            snapshot.content!,
            target,
          )
          .ignore();
    }
    bool current(OriginalHostController host) =>
        mounted &&
        identical(widget.controller, controller) &&
        widget.session.book.contentVersion == snapshot.book.contentVersion &&
        identical(_hosts[ordinal], host);
    return OriginalChapter(
      deferStartUntilCurrent:
          ReaderDeliveryExperiments.originalPriority &&
          _parallelTarget?.chapter == ordinal &&
          ordinal != snapshot.chapterIndex,
      session: widget.controller.source,
      ordinal: ordinal,
      fontSizePx: _fontSizePx(context, settings),
      lineHeight: settings.lineHeight,
      paragraphGapEm: settings.paragraphGapEm,
      columnMarginPx: margin,
      indent: settings.indent,
      fontFamily: settings.useOriginalFont
          ? ''
          : settings.fontFamily ?? 'sans-serif',
      fontWeight: settings.fontWeight,
      // 相邻章各自的落位：上一章落章末、下一章落章首，滑进来时正是要看到的那一页
      initialFraction: initialFraction,
      themeColors: _themeColors(),
      information:
          readerInformation(
              context,
              ref,
              widget.session,
              settings,
              widget.theme,
              ordinal,
              initialFraction ?? widget.session.chapterProgress,
              showReturnProgress: !isNeighbor,
            ).toHost(
              widget.session.bookProgressAt(ordinal, 0),
              widget.session.bookProgressAt(ordinal, 1),
            )
            ..['pageTurnEffect'] = settings.pageTurnEffect.name
            ..['contentProgress'] = ref
                .read(readerSessionProvider(widget.bookId).notifier)
                .usesContentProgress
            ..['paintInHost'] =
                settings.pageTurnEffect != PageTurnEffect.curl &&
                settings.pageTurnEffect != PageTurnEffect.cover,
      preparationRevision: (
        ref.watch(annotationsProvider(widget.bookId)).hasValue,
        _highlightSignature(
          ref.watch(readerHighlightsProvider(widget.bookId)),
          includeChapter: false,
        ),
      ),
      prepare: (host) async {
        if (ReaderDeliveryExperiments.contentTarget && !host.contentMapReady) {
          if (!current(host)) return;
          final awaitingTitles = ref
              .read(progressTitlesProvider(bookId))
              .isLoading;
          final titles = await traceTurnStep(
            'prepare titles chapter=$ordinal',
            () => ref.read(progressTitlesProvider(bookId).future),
          );
          if (awaitingTitles) {
            // 目录完成会重建信息栏配置；让同一帧的最终章名先进入frame，
            // 再批量启动网页，不能把准备期间的兜底章名带到第一张可见页。
            await WidgetsBinding.instance.endOfFrame;
          }
          if (!current(host)) return;
          await host.setContentTitles([
            for (final entry in titles.where(
              (t) => t.chapterId == snapshot.chapters[ordinal].id,
            ))
              {'progress': entry.progress, 'title': entry.title},
          ]);
          final chapter = snapshot.chapters[ordinal];
          final content = ordinal == snapshot.chapterIndex
              ? snapshot.content!
              : await ref
                    .read(chapterContentRepositoryProvider)
                    .chapter(bookId, chapter);
          final map = await traceTurnStep(
            'prepare map chapter=$ordinal',
            () => controller.positionMap(
              ordinal,
              chapter.href ?? '',
              content,
              Locator(
                bookId: widget.bookId,
                contentVersion: snapshot.book.contentVersion,
                chapterId: chapter.id,
                blockId: '',
                utf16Offset: 0,
              ),
            ),
          );
          if (!current(host)) return;
          final progressMap = await traceTurnStep(
            'prepare progress-map chapter=$ordinal',
            () async => map.progressMap,
          );
          await host.setContentMap(progressMap);
        }
        if (!current(host)) return;
        final exact = ref
            .read(readerSessionProvider(widget.bookId).notifier)
            .peekOriginalExactPosition(ordinal);
        host.initialDomPoint = null;
        if (ReaderDeliveryExperiments.originalWindow &&
            exact != null &&
            snapshot.content != null &&
            ordinal == snapshot.chapterIndex) {
          host.initialDomPoint = await controller.resolvePosition(
            ordinal,
            snapshot.chapter.href ?? '',
            snapshot.content!,
            exact,
          );
        }
        if (!current(host)) return;
        await _prepareChapterHighlights(ordinal, host);
      },
      onControllerReady: (host) {
        _hosts[ordinal] = host;
        final trace = _turnLog;
        if (trace != null && trace.endUs == null) {
          host.beginTurnDiagnostics(trace);
        }
      },
      onHostEvent: (raw) =>
          _onRawMessage(raw, isNeighbor: isNeighbor, ordinal: ordinal),
    );
  }

  /// 正文字号（像素）：用户字号 × 系统字号缩放。
  ///
  /// WebView 不感知 Flutter 的缩放，所以必须由 Dart 算好再传下去
  /// （与简化模式同一个来源，两模式口径差异见 W10 实测）。
  double _fontSizePx(BuildContext context, ReadingSettings settings) =>
      MediaQuery.textScalerOf(context).scale(settings.fontSize.toDouble());

  Map<String, String> _themeColors() => {
    'bg': hexOf(widget.theme.background),
    if (widget.theme.texture != null)
      'backgroundImage': widget.theme.texture!.url,
    'text': hexOf(widget.theme.primary),
    'link': hexOf(readingLinkColor(widget.theme)),
  };

  /// 把可用区域对应的排版参数交给会话（不预取相邻章：原书模式用不上）。
  ///
  /// 宽度变化不用在这里处理：[OriginalBody] 自己盯着自己的宽度，变了会通知
  /// 宿主页重新分栏并保持位置。
  void _submitIfChanged(Size contentSize) {
    final options = LayoutOptions(
      settings: widget.settings,
      contentSize: contentSize,
      textScaler: MediaQuery.textScalerOf(context),
    );
    if (_submitted == options.layoutSignature) return;
    _submitted = options.layoutSignature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(readerSessionProvider(widget.bookId).notifier)
            // 原书模式的正文由 WebView 画：这里只记排版参数，不排简化版。
            // 排一整章按字数花时间（整本正文一个文件的书写，实测 2.2 秒），
            // 只有切回简化模式才用得上，那一步再排（setLayoutMode / goToLocator）
            .applyViewport(options, prefetch: false, paginate: false),
      );
    });
  }
}
