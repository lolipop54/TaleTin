part of '../views/reader_view.dart';

// 正文、图片与翻页材料的组装；状态与视口提交仍留在 PageArea。
extension _ReaderPageContent on _PageAreaState {
  Widget _page(ReaderSession session, ReadingSettings settings, Size pageSize) {
    final layout = session.layout;
    if (layout == null || !session.isReady) {
      // 首屏：参数已提交，等排版结果；此处保持稳定加载态，不先闪空页
      return const _PreparingState();
    }
    final resolve = ref.read(chapterContentRepositoryProvider);
    final bookId = widget.bookId;
    final version = session.book.contentVersion;

    // 书页包括顶部信息、正文及底部状态，静态页与翻页共用完整画布。
    // 正文仍按扣除信息区后的尺寸排版，选区坐标也使用相同原点。
    // 选区（原型）：只画在本章内，跨章选区不验证
    final selection = widget.state.selection;
    // 持久高亮（笔记与高亮记录）：铺在文字下面，随分页重算（S6）。
    // 第一次还没读出来时先不画这一页：等高亮到位再一起显示，
    // 不然会先看到一段没有底色的正文、隔一下底色才补上
    final annotationsAsync = ref.watch(annotationsProvider(bookId));
    final annotations = ref.watch(readerHighlightsProvider(bookId));
    if (!annotationsAsync.hasValue && annotationsAsync.isLoading) {
      return const _PreparingState();
    }
    final speech = ref.watch(listeningViewStateProvider).value;
    final unit = speech?.hasSession == true ? speech?.activeUnit : null;
    List<Rect> rectsFor(ChapterLayout source, int index) {
      // 点已有高亮选出来的选区不铺临时底色：那一段本来就有高亮底色，再叠一层
      // 看起来就像高亮被画了两遍、颜色变重（真机反馈）
      if (selection == null || widget.state.selectionFromMark) return const [];
      // 跨章选区：按章节顺序裁到这一章（首章到章末、末章从章首、中间章整章）
      return ref
          .read(readerEngineProvider)
          .selectionRects(
            source,
            index,
            selection.start,
            selection.end,
            chapterOrdinals: chapterOrdinalsOf(session.chapters),
          );
    }

    // 这一页上每条标注的矩形（只算本章里的记录，跨章选区由引擎裁到本章）
    List<({Annotation annotation, List<Rect> rects})> marksFor(
      ChapterLayout source,
      int index,
    ) {
      if (annotations.isEmpty) return const [];
      final ordinals = chapterOrdinalsOf(session.chapters);
      final engine = ref.read(readerEngineProvider);
      final result = <({Annotation annotation, List<Rect> rects})>[];
      for (final annotation in annotations) {
        if (annotation.isBookmark || annotation.color == null) continue;
        final end = annotation.end ?? annotation.start;
        final first = ordinals[annotation.start.chapterId],
            last = ordinals[end.chapterId];
        final current = ordinals[source.chapterId];
        if (first == null ||
            last == null ||
            current == null ||
            current < first ||
            current > last) {
          continue;
        }
        final rects = engine.selectionRects(
          source,
          index,
          annotation.start,
          end,
          chapterOrdinals: ordinals,
        );
        if (rects.isEmpty) continue;
        result.add((annotation: annotation, rects: rects));
      }
      return result;
    }

    List<CaretGeometry> handlesFor(ChapterLayout source, int index) {
      if (selection == null || widget.state.selectionFromMark) return const [];
      final engine = ref.read(readerEngineProvider);
      return [
        for (final end in [false, true])
          if (end != _draggedSelectionEnd)
            ?engine.caretAt(
              source,
              index,
              end ? selection.end : selection.start,
              atEnd: end,
            ),
      ];
    }

    List<PageThoughtMarker> thoughtsFor(ChapterLayout source, int index) => [
      for (final mark in marksFor(source, index))
        if (mark.annotation.body.trim().isNotEmpty &&
            ref
                    .read(readerEngineProvider)
                    .caretAt(
                      source,
                      index,
                      mark.annotation.end!,
                      atEnd: true,
                    ) !=
                null)
          PageThoughtMarker(
            id: mark.annotation.id,
            rect: thoughtMarkerRect(mark.rects.last, source.contentSize.width),
            color: readingLinkColor(widget.settings.theme),
          ),
    ];

    PageCanvas content(ChapterLayout source, int index) => PageCanvas(
      onPrepared: source.samePageAs(layout, index, session.pageIndex)
          ? (prepared) {
              _currentMaterial?.dispose();
              _currentMaterial = prepared.clone();
            }
          : null,
      onReady: source.samePageAs(layout, index, session.pageIndex)
          ? () {
              if (!ReaderDeliveryExperiments.incremental) {
                _preparedLayout = source;
                _preparedPage = index;
                return;
              }
              final reader = ref.read(readerSessionProvider(bookId).notifier);
              final next = reader.peekNext(), previous = reader.peekPrevious();
              _prepareWindow(source, index, [
                if (next != null) content(next.layout, next.pageIndex),
                if (previous != null)
                  content(previous.layout, previous.pageIndex),
              ], current: content(source, index));
            }
          : null,
      textCache: _textCache,
      information: readerInformation(
        context,
        ref,
        session,
        settings,
        widget.settings.theme,
        session.chapters.indexWhere((c) => c.id == source.chapterId),
        source.progressOfPage(index),
        bookmarked:
            ref
                .watch(bookmarksProvider(bookId))
                .value
                ?.any(
                  (mark) =>
                      mark.locator.chapterId == source.chapterId &&
                      source.pageIndexOf(mark.locator) == index,
                ) ??
            false,
        showReturnProgress:
            source.chapterId == session.chapter.id &&
            index == session.pageIndex,
      ),
      layout: source,
      pageIndex: index,
      theme: widget.settings.theme,
      selectionRects: rectsFor(source, index),
      selectionHandles: handlesFor(source, index),
      handleColor: context.gtColors.actionPrimary,
      thoughtMarkers: thoughtsFor(source, index),
      highlights: [
        for (final mark in marksFor(source, index))
          PageHighlight(
            color: pageHighlightColorOf(mark.annotation.color),
            rects: mark.rects,
          ),
      ],
      speechRects: unit == null
          ? const []
          : speechRectsForPage(
              layout: source,
              pageIndex: index,
              from: unit.sentenceStart,
              to: unit.sentenceEnd,
            ),
      resolveResource: (path) =>
          resolve.resourceAbsolutePath(bookId, version, path),
    );
    Widget page(ChapterLayout source, int index) => content(source, index);
    final peekNext = ref
        .read(readerSessionProvider(bookId).notifier)
        .peekNext();
    final peekPrevious = ref
        .read(readerSessionProvider(bookId).notifier)
        .peekPrevious();

    // 同一轮resolve和动画共用目标任务。已解码的邻页直接使用，避免PDF命中后
    // 仍重新排队检查文件；尚未准备好时继续走仓库补图与失败恢复。
    final adjacentTasks = <bool, Future<SpreadPageRef?>>{};
    Future<SpreadPageRef?> adjacent(bool forward) =>
        adjacentTasks.putIfAbsent(forward, () {
          final target = forward ? peekNext : peekPrevious;
          if (target != null &&
              _pageMaterials.contains(
                content(target.layout, target.pageIndex),
                createLocalImageConfiguration(context),
              )) {
            return Future.value(target);
          }
          return ref
              .read(readerSessionProvider(bookId).notifier)
              .prepareAdjacent(forward);
        });

    final manual = PageTurnArea(
      key: _inputKey,
      inputRevision: settings,
      effect: settings.pageTurnEffect,
      onManualStart: () => unawaited(
        ref.read(automaticReadingProvider(bookId).notifier).discard(),
      ),
      onTapIntercept: (point) async {
        final auto = ref.read(automaticReadingProvider(bookId).notifier);
        if (auto.consumePauseTap()) return true;
        final ratio = point.dx / pageSize.width;
        if (auto.canResume &&
            ratio >= GtReadingTapZones.previousEdge &&
            ratio <= GtReadingTapZones.nextEdge) {
          auto.centerTap();
          return true;
        }
        await auto.discard();
        if (!mounted) return true;
        final canvas = content(layout, session.pageIndex);
        final size = context.size!;
        final origin = Offset(
          (size.width - layout.contentSize.width) / 2,
          (size.height -
                  layout.contentSize.height +
                  (canvas.information?.top ?? 0) -
                  (canvas.information?.bottom ?? 0)) /
              2,
        );
        final localPoint = point - origin;
        for (final marker in canvas.thoughtMarkers) {
          if (!marker.rect.inflate(8).contains(localPoint)) continue;
          final note = annotations.firstWhere((a) => a.id == marker.id);
          await ref
              .read(readerSessionProvider(bookId).notifier)
              .beginManualReading();
          if (!mounted) return true;
          final box = context.findRenderObject()! as RenderBox;
          await showThoughtPopover(
            context,
            body: note.body,
            theme: widget.settings.theme,
            anchor: marker.rect.shift(box.localToGlobal(origin)),
          );
          return true;
        }
        // 点到已有的高亮/笔记：直接开它的操作菜单（改颜色、编辑想法、删除），
        // 不再翻页（S6）；矩形已经是页内容盒坐标，减掉原点即可命中。
        // fromMark：只摆菜单，不画手柄与临时底色
        for (final mark in marksFor(layout, session.pageIndex)) {
          if (mark.annotation.id == searchPreviewId) continue;
          final local = point - origin;
          if (mark.rects.any((rect) => rect.inflate(2).contains(local))) {
            ref
                .read(readerProvider.notifier)
                .startSelection(
                  mark.annotation.start,
                  mark.annotation.end ?? mark.annotation.start,
                  fromMark: true,
                );
            return true;
          }
        }
        // 脚注标记：先弹脚注内容，不直接跳页；气泡右下角再提供“跳转”。
        // 按矩形命中（脚注标记很小，按字符反查容易点偏）。
        final link = readerLinkNearPoint(layout, session.pageIndex, localPoint);
        if (link != null) {
          {
            if (!mounted) return true;
            final box = context.findRenderObject()! as RenderBox;
            final shown = await openReaderLink(
              context,
              ref: ref,
              bookId: bookId,
              chapters: session.chapters,
              link: link.link,
              footnote: link.footnote,
              anchor: box.localToGlobal(point),
              theme: widget.settings.theme,
            );
            if (!shown && mounted) {
              ref
                  .read(readerProvider.notifier)
                  .showNotice(link.footnote ? '没有找到脚注内容' : '书内链接读取失败，请重试');
            }
            return true;
          }
        }
        // 行内图片（生僻字）只做单张大图预览，不进入连续图片窗口：
        // 它混在正文里，前后通常都是文字，不是漫画分页序列。
        for (final fragment in layout.page(session.pageIndex)!.fragments) {
          if (!mounted) return true;
          final image = fragment.inlineImageAt(localPoint);
          if (image == null) continue;
          final path = image.resourcePath;
          final file = File(canvas.resolveResource(path));
          if (path.toLowerCase().endsWith('.svg')) {
            await showReaderSvg(
              context,
              SvgFileLoader(file),
              formula: image.formula != null,
            );
          } else {
            await showReaderImage(context, FileImage(file));
          }
          return true;
        }
        for (final fragment in layout.page(session.pageIndex)!.fragments) {
          if (!mounted) return true;
          final path = fragment.block.resourcePath;
          final rect = fragment.imageRectIn(layout.contentSize.width);
          if (rect != null && path != null && rect.contains(localPoint)) {
            final file = File(canvas.resolveResource(path));
            if (await tryReaderImageGallery(
              context,
              ref,
              bookId,
              path,
              chapterId: session.chapter.id,
              blockId: fragment.block.blockId,
            )) {
              return true;
            }
            if (!mounted) return true;
            if (path.toLowerCase().endsWith('.svg')) {
              await showReaderSvg(context, SvgFileLoader(file));
            } else {
              await showReaderImage(context, FileImage(file));
            }
            return true;
          }
        }
        return false;
      },
      resolvePage: (direction) async {
        final target = await adjacent(direction == PageTurnDirection.forward);
        if (!mounted || target == null) {
          adjacentTasks.remove(direction == PageTurnDirection.forward);
          return null;
        }
        return page(target.layout, target.pageIndex);
      },
      prepareFold: (direction) async {
        final forward = direction == PageTurnDirection.forward;
        try {
          final target = await adjacent(forward);
          if (!mounted || target == null) return null;
          return await FoldFrames.load(
            content(layout, session.pageIndex),
            content(target.layout, target.pageIndex),
            createLocalImageConfiguration(context),
            rasterCache: _rasterCache,
            materialCache: _pageMaterials,
          );
        } finally {
          // 只合并本轮解析与动画；取消或图片失败后的新手势必须可以重新补图。
          adjacentTasks.remove(forward);
        }
      },
      // 翻页动画期间暂停菜单与手柄触摸，手柄外观已在书页画布中。
      traceLabel: 'simplified',
      onSettling: (direction) {
        _rasterBackward = direction == PageTurnDirection.backward;
        LayoutWorkGate.hold(_motionWorkOwner);
        _setPageTurning(true);
      },
      onGestureFinished: () {
        LayoutWorkGate.release(_motionWorkOwner);
        _setPageTurning(false);
      },
      turnId: '${layout.chapterId}#${session.pageIndex}',
      currentPage: page(layout, session.pageIndex),
      nextPage: peekNext == null
          ? null
          : page(peekNext.layout, peekNext.pageIndex),
      previousPage: peekPrevious == null
          ? null
          : page(peekPrevious.layout, peekPrevious.pageIndex),
      // 有选区时点正文中间先取消选区，不切控制栏（原型交互）
      onCenterTap: () {
        final vm = ref.read(readerProvider.notifier);
        if (widget.state.selection != null) {
          vm.clearSelection();
          return;
        }
        ref.read(automaticReadingProvider(bookId).notifier).centerTap();
      },
      onTurn: (direction) async {
        final notifier = ref.read(readerSessionProvider(bookId).notifier);
        final result = direction == PageTurnDirection.forward
            ? await notifier.nextPage()
            : await notifier.previousPage();
        if (!mounted) return false;
        switch (result) {
          case PageTurnResult.moved:
            return true;
          case PageTurnResult.atBookStart:
            _showNotice('已经是第一页了');
            return false;
          case PageTurnResult.atBookEnd:
            _showNotice('已经是最后一页了');
            return false;
        }
      },
    );
    final size = pageSize;
    return AutomaticScanArea(
      bookId: bookId,
      page: (
        bookId: bookId,
        contentVersion: version,
        layout: (
          layout.options.layoutSignature,
          widget.settings.theme,
          annotations,
        ),
        page: (layout.chapterId, session.pageIndex),
      ),
      ready: () =>
          mounted &&
          widget.session.isReady &&
          !_pageTurning &&
          layout.samePageAs(
            ref.read(readerSessionProvider(bookId)).value?.layout,
            session.pageIndex,
          ) &&
          LayoutOptions(
                cssDark: widget.settings.theme.isNight,
                settings: ref
                    .read(readerSettingsProvider(bookId))
                    .requireValue
                    .settings,
                contentSize: layout.contentSize,
                textScaler: layout.options.textScaler,
                // 与当前排版用同一个「是否补章题」开关，签名才有可比性。
                insertChapterTitle: layout.options.insertChapterTitle,
              ).layoutSignature ==
              layout.options.layoutSignature,
      bounds: Offset.zero & size,
      paper: widget.settings.theme.background,
      line: widget.settings.theme.secondary,
      child: manual,
      prepare: (_) async {
        final notifier = ref.read(readerSessionProvider(bookId).notifier);
        final target = await notifier.prepareAdjacent(true);
        if (!mounted) throw StateError('阅读页已关闭');
        final targetContent = target == null
            ? null
            : await resolve.chapter(
                bookId,
                session.chapters.firstWhere(
                  (c) => c.id == target.layout.chapterId,
                ),
              );
        if (!mounted) throw StateError('阅读页已关闭');
        final frames = await ScanFrames.load(
          content(layout, session.pageIndex),
          target == null ? null : content(target.layout, target.pageIndex),
          createLocalImageConfiguration(context),
          size,
          MediaQuery.devicePixelRatioOf(context),
        );
        return ScanPreparation(
          frames,
          target == null
              ? null
              : () => notifier.commitScanPage(
                  current: layout,
                  currentPage: session.pageIndex,
                  next: target.layout,
                  nextPage: target.pageIndex,
                  content: targetContent!,
                ),
          targetPage: target == null
              ? null
              : (target.layout.chapterId, target.pageIndex),
        );
      },
    );
  }
}
