import 'dart:async';

import 'package:taletin/core/diagnostics/app_errors.dart';

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'table_painter.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/locator.dart' show SelectionRange;
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import '../../../../engine/layout/measured_block.dart';
import '../../../../engine/selection/scroll_selection.dart';
import '../../../../engine/selection/selection_range.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_loading.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_source_change.dart';
import '../view_models/scroll_window.dart';
import '../view_models/original_layout_controller.dart';
import '../view_models/automatic_reading.dart';
import 'page_information.dart';
import 'reader_information.dart';
import 'book_paper.dart';
import 'scroll_resources.dart';
import 'scroll_selection_layer.dart';
import 'reader_image_viewer.dart';
import 'reader_image_gallery.dart';

part 'simplified_automatic_motion.dart';
part 'simplified_scroll_selection.dart';
part 'simplified_scroll_tap.dart';

class SimplifiedScrollArea extends ConsumerStatefulWidget {
  const SimplifiedScrollArea({
    super.key,
    required this.bookId,
    required this.session,
    required this.settings,
  });
  final String bookId;
  final ReaderSession session;
  final ReaderSettingsState settings;
  @override
  ConsumerState<SimplifiedScrollArea> createState() =>
      SimplifiedScrollAreaState();
}

class SimplifiedScrollAreaState extends ConsumerState<SimplifiedScrollArea>
    with
        SingleTickerProviderStateMixin,
        _SimplifiedAutomaticMotion,
        _SimplifiedScrollSelection,
        _SimplifiedScrollTap {
  @override
  late final ScrollWindow _window;
  @override
  late final ScrollResources _resources;
  Timer? _reportTimer;
  bool _chapterFailed = false;
  bool _completionDrag = false;
  String? _signature;
  int? _jump;
  int _preparation = 0;
  double? _stableHeight;
  late final ReaderSessionNotifier _cachedSession;
  @override
  ReaderSessionNotifier get _session => _cachedSession;
  bool get isReady =>
      _window.isReady && _window.options?.layoutSignature == _signature;

  Future<void> volumeTurn(bool forward) async {
    if (!isReady || !_window.controller.hasClients || _window.busy) return;
    await _automatic.discard();
    await _session.beginManualReading();
    await _window.maintain();
    await _warmNearby();
    if (!mounted || !isReady || !_window.controller.hasClients) return;
    final position = _window.controller.position;
    final delta = position.viewportDimension * 0.85 * (forward ? 1 : -1);
    _window.controller.jumpTo(
      (_window.controller.offset + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    _window.report();
  }

  @override
  void initState() {
    super.initState();
    _cachedSession = ref.read(readerSessionProvider(widget.bookId).notifier);
    _resources = ScrollResources(
      (path) => ref
          .read(chapterContentRepositoryProvider)
          .resourceAbsolutePath(
            widget.bookId,
            widget.session.book.contentVersion,
            path,
          ),
    );
    _window = ScrollWindow(
      bookId: widget.bookId,
      version: widget.session.book.contentVersion,
      chapters: widget.session.chapters,
      load: (chapter) => ref
          .read(chapterContentRepositoryProvider)
          .chapter(widget.bookId, chapter),
      onPosition: (content, anchor, token) {
        if (mounted) {
          if (_session.reportScrollPosition(
            content,
            anchor,
            jumpToken: token,
            atEnd:
                _window.entries.last.index ==
                    widget.session.chapters.length - 1 &&
                _window.controller.offset >=
                    _window.controller.position.maxScrollExtent - .5,
          )) {
            _session.completeAnnotationLanding();
          }
        }
      },
      prepareResources: _resources.warm,
      onError: _loadingFailed,
    );
    _window.addListener(_changed);
    _window.controller.addListener(_scrolled);
    _initAutomatic();
    _initSelection(_contentTap);
  }

  void _changed() {
    _retainNearby();
    if (mounted) setState(() {});
  }

  void _retainNearby() {
    if (!_window.controller.hasClients || !_window.isReady) return;
    final paths = <String>{};
    var before = 0.0;
    for (final entry in _window.entries) {
      paths.addAll(
        _resources.pathsNear(
          entry.layout,
          _window.controller.offset - before,
          _window.options!.contentHeight,
        ),
      );
      before += entry.layout.height;
    }
    _resources.retain(paths);
  }

  void _scrolled() {
    _reportTimer ??= Timer(const Duration(milliseconds: 250), () {
      _reportTimer = null;
      if (!mounted) return;
      _window.report();
      _retainNearby();
      unawaited(_warmNearby());
    });
    if (!_chapterFailed) {
      unawaited(_window.maintain().catchError(_loadingFailed));
    }
  }

  Future<void> _warmNearby() async {
    if (!_window.controller.hasClients || !_window.isReady) return;
    var before = 0.0;
    final jobs = <Future<void>>[];
    // 一屏可能包含几章，下一章的图片进入屏幕前也必须准备。
    for (final entry in _window.entries) {
      jobs.add(
        _resources.warm(
          entry.layout,
          _window.controller.offset - before,
          _window.options!.contentHeight,
        ),
      );
      before += entry.layout.height;
    }
    await Future.wait(jobs);
    // 图片自己的画笔监听 ScrollResources；没有新章节时无需重建整个列表。
  }

  void _loadingFailed(Object error, StackTrace stack) {
    if (!mounted) return;
    if (isSourceChange(error)) {
      ref
          .read(readerSourceChangeProvider(widget.bookId).notifier)
          .markChanged();
      return;
    }
    _chapterFailed = true;
    AppErrors.report(error, stack, operation: '滚动章节读取失败');
    _automatic.finish('章节读取失败，已暂停；可再次开始重试');
  }

  @override
  void dispose() {
    _disposeAutomatic();
    _reportTimer?.cancel();
    _window.removeListener(_changed);
    _window.dispose();
    _resources.dispose();
    super.dispose();
  }

  void _prepare(LayoutOptions options) {
    final jump = widget.session.scrollJump;
    if (_signature == options.layoutSignature && _jump == jump?.token) return;
    final requested = _jump != jump?.token;
    _chapterFailed = false;
    _signature = options.layoutSignature;
    _jump = jump?.token;
    final preparation = ++_preparation;
    final anchor = requested
        ? jump?.locator ?? _session.scrollOpeningAnchor
        : _session.scrollOpeningAnchor;
    final index = anchor == null
        ? widget.session.chapterIndex
        : widget.session.chapters.indexWhere((c) => c.id == anchor.chapterId);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || preparation != _preparation) return;
      await _session.setScrolling(true);
      try {
        await _window.open(
          index,
          options,
          anchor,
          jumpToken: jump?.token,
          animated: jump != null && _session.speechScrollToken == jump.token,
        );
      } on Object catch (error, stack) {
        AppErrors.report(error, stack, operation: '滚动正文准备失败', notify: mounted);
        if (mounted) {
          if (isSourceChange(error)) {
            ref
                .read(readerSourceChangeProvider(widget.bookId).notifier)
                .markChanged();
            return;
          }
          ref.read(readerProvider.notifier).showNotice('正文准备失败：$error');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final settings = widget.settings.settings;
      final info = readerInformation(
        context,
        ref,
        widget.session,
        settings,
        widget.settings.theme,
        widget.session.chapterIndex,
        widget.session.chapterProgress,
      );
      if (MediaQuery.viewInsetsOf(context).bottom == 0) {
        _stableHeight = box.maxHeight;
      }
      final height = _stableHeight ?? box.maxHeight;
      final width = math.min(box.maxWidth, settings.landscape ? box.maxWidth : GtSize.readingMaxWidth);
      final options = LayoutOptions(
        settings: settings,
        contentSize: Size(
          width - 2 * (settings.horizontalPadding + (settings.bookEdges ? bookEdgeWidth : 0)),
          height - info.top - info.bottom - 48,
        ),
        textScaler: MediaQuery.textScalerOf(context),
      );
      _prepare(options);
      if (_window.options == null) return const Center(child: BookLoading());
      return Stack(
        children: [
          Positioned.fill(
            top: info.top + 24,
            bottom: info.bottom + 24,
            left: (box.maxWidth - _window.options!.contentWidth) / 2,
            right: (box.maxWidth - _window.options!.contentWidth) / 2,
            child: NotificationListener<ScrollNotification>(
              onNotification: (event) {
                if (event is ScrollStartNotification &&
                    event.dragDetails != null) {
                  _completionDrag = true;
                  unawaited(_session.beginManualReading());
                }
                if (event is ScrollEndNotification && !_autoTicker.isActive) {
                  if (_completionDrag &&
                      _window.entries.last.index ==
                          widget.session.chapters.length - 1 &&
                      event.metrics.extentAfter < 1) {
                    ref.read(readerProvider.notifier).showNotice('已到全书末尾');
                  }
                  _completionDrag = false;
                  _window.report();
                  unawaited(_session.persist());
                }
                return false;
              },
              child: ScrollSelectionLayer(
                bookId: widget.bookId,
                backend: _selectionBackend,
                theme: widget.settings.theme,
                child: ListView.custom(
                  key: const ValueKey('continuous-text'),
                  controller: _window.controller,
                  padding: EdgeInsets.zero,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(500),
                  itemExtentBuilder: (i, _) => _window.cellAt(i).cell.height,
                  childrenDelegate: _ScrollCellsDelegate(
                    (context, i) {
                      final cell = _window.cellAt(i).cell;
                      if (cell.table.isNotEmpty) {
                        return Stack(
                          key: _window.keyAt(i),
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: ScrollTextPainter(
                                  cell,
                                  _window.options!,
                                  widget.settings.theme.primary,
                                  widget.settings.theme.secondary,
                                ),
                              ),
                            ),
                            for (final fragment in cell.table)
                              if (!fragment.frameOnly &&
                                  fragment.block.imageSize != null)
                                Positioned(
                                  left: fragment.block.inset,
                                  top: fragment.y,
                                  child: _resources.view(
                                    fragment.block.resourcePath!,
                                    fragment.block.imageSize!,
                                    widget.settings.theme.secondary,
                                    fragment.block.alt,
                                  ),
                                ),
                          ],
                        );
                      }
                      final size = cell.measured.imageSize;
                      if (size == null) {
                        return CustomPaint(
                          key: _window.keyAt(i),
                          painter: ScrollTextPainter(
                            cell,
                            _window.options!,
                            widget.settings.theme.primary,
                            widget.settings.theme.secondary,
                          ),
                        );
                      }
                      return Padding(
                        key: _window.keyAt(i),
                        padding: EdgeInsets.only(top: cell.gap),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: _resources.view(
                            cell.block.resourcePath!,
                            size,
                            widget.settings.theme.secondary,
                            cell.block.alt,
                          ),
                        ),
                      );
                    },
                    count: _window.cellCount,
                    height: _window.height,
                    findIndex: _window.indexOfKey,
                  ),
                ),
              ),
            ),
          ),
          if (settings.bookEdges)
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter:
              BookPaperPainter(widget.settings.theme.background, decorationOnly: true)))),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: ScrollInformationPainter(info)),
            ),
          ),
        ],
      );
    },
  );
}

/// 行高已经测好，告诉列表真实总高度，避免临近书末时用平均行高估算并回弹。
class _ScrollCellsDelegate extends SliverChildBuilderDelegate {
  _ScrollCellsDelegate(
    super.builder, {
    required int count,
    required this.height,
    required ChildIndexGetter findIndex,
  }) : super(childCount: count, findChildIndexCallback: findIndex);
  final double height;
  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => height;
}

class ScrollTextPainter extends CustomPainter {
  ScrollTextPainter(this.cell, this.options, this.color, this.ruleColor);
  final ScrollCell cell;
  final LayoutOptions options;
  final Color color;
  final Color ruleColor;
  @override
  void paint(Canvas canvas, Size size) {
    if (cell.table.isNotEmpty) {
      paintTableFragments(canvas, cell.table, options, color, ruleColor);
      return;
    }
    var top = cell.gap;
    final block = cell.measured;
    for (var i = cell.from; i < cell.to; i++) {
      final painter = block.createSingleLinePainter(
        lineIndex: i,
        textScaler: options.textScaler,
        color: color,
        letterSpacing: block.justifySpacingFor(
          i,
          maxWidth: options.contentWidthFor(block.kind),
          textScaler: options.textScaler,
          enabled: block.kind.name == 'paragraph',
        ),
      );
      painter.paint(canvas, Offset(block.inset, top));
      painter.dispose();
      top += block.lines[i].height;
    }
    if (block.isTitleDecoration && cell.to == block.lines.length) {
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          top + kTitleRuleGap,
          kTitleRuleWidth,
          kTitleRuleThickness,
        ),
        Paint()..color = ruleColor.withValues(alpha: 0.66),
      );
    }
  }

  @override
  bool shouldRepaint(ScrollTextPainter old) =>
      old.cell != cell || old.color != color || old.ruleColor != ruleColor;
}

class ScrollInformationPainter extends CustomPainter {
  ScrollInformationPainter(this.info);
  final PageInformation info;
  @override
  void paint(Canvas canvas, Size size) => info.paint(canvas, size);
  @override
  bool shouldRepaint(ScrollInformationPainter old) => true;
}
