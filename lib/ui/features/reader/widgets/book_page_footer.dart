import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../data/services/book_page_counter.dart';
import '../../../../domain/repositories/reading_controls_repository.dart';
import '../../../../engine/layout/chapter_layout.dart';
import '../../../../engine/layout/book_page_options.dart';
import '../../../../platform/channels/reading_fonts.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../core/theme/app_theme.dart';
import '../view_models/reader_session_state.dart';
import '../view_models/reader_session_view_model.dart' show SpreadPageRef;
import 'page_information.dart';
import 'fold_frames.dart';
import 'page_ink.dart';

part 'curl_page_footer.dart';

final showBookPagesProvider = Provider<bool>(
  (ref) =>
      ref.watch(bookPageCounterFactoryProvider) != null &&
      ref.watch(
            readingControlsProvider.select((s) => s.value?.progressStyle),
          ) ==
          ReadingProgressStyle.pages,
);

/// 同一书籍和版面共用一次后台计数。翻动的两张纸只订阅页脚，不各自启动进程。
class BookPagePaper extends ConsumerStatefulWidget {
  const BookPagePaper({
    super.key,
    required this.session,
    required this.layout,
    required this.page,
    required this.options,
    required this.info,
    required this.ready,
    required this.enabled,
    required this.child,
  });
  final ReaderSession session;
  final ChapterLayout? layout;
  final int page;
  final LayoutOptions options;
  final PageInformation info;
  final bool ready, enabled;
  final Widget child;

  @override
  ConsumerState<BookPagePaper> createState() => _BookPagePaperState();
}

class _BookPagePaperState extends ConsumerState<BookPagePaper>
    with WidgetsBindingObserver {
  BookPageCounter? _count;
  Object? _key;
  final _chapters = <String, int>{};
  late bool _visible;
  bool _animate = false;
  final _phase = ValueNotifier<int>(0);
  Timer? _clock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    _syncClock();
  }

  // 一张纸的正反面和下一张纸使用同一拍，折痕穿过加载标记时两半也能对齐。
  void _syncClock() {
    final c = _count;
    if (_visible &&
        _animate &&
        c != null &&
        c.indexReady &&
        !c.complete &&
        !c.failed) {
      _clock ??= Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _phase.value = (_phase.value + 1) % 4,
      );
    } else {
      _clock?.cancel();
      _clock = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _visible = _isVisible(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    _update();
  }

  @override
  void didUpdateWidget(BookPagePaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session.chapters, widget.session.chapters)) {
      _chapters.clear();
    }
    _update();
  }

  int chapterOf(ChapterLayout layout) {
    final s = widget.session;
    if (s.chapter.id == layout.chapterId) return s.chapterIndex;
    return _chapters.putIfAbsent(
      layout.chapterId,
      () => s.chapters.indexWhere((c) => c.id == layout.chapterId),
    );
  }

  void _update() {
    final w = widget;
    if (!w.enabled) {
      _count?.dispose();
      _count = null;
      _syncClock();
      _key = null;
      return;
    }
    final session = w.session;
    final key = (
      session.book.id,
      session.book.contentVersion,
      w.options.layoutSignature,
      pageScaleSamples(w.options.textScaler)?.join(','),
      ReadingFonts.environmentRevision,
    );
    if (key == _key ||
        !w.ready ||
        w.layout?.options.layoutSignature != w.options.layoutSignature) {
      return;
    }
    _count?.dispose();
    _key = key;
    final count = _count = ref.read(bookPageCounterFactoryProvider)!();
    count.addListener(_syncClock);
    _syncClock();
    count.pause(!_visible);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || count != _count) return;
      unawaited(
        count.start(
          session.book,
          session.chapters,
          w.options,
          ref.read(libraryRootPathProvider),
          ref.read(cacheRootPathProvider),
        ),
      );
    });
  }

  // Windows 失去焦点后窗口仍可见。只有界面真正隐藏时才暂停独立进程。
  static bool _isVisible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _isVisible(state);
    if (visible == _visible) return;
    setState(() => _visible = visible);
    _count?.pause(!visible);
    _syncClock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _phase.dispose();
    _count?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BookPagePaperScope(
    count: _count,
    current: widget.layout == null
        ? null
        : (layout: widget.layout!, pageIndex: widget.page),
    info: widget.info,
    phase: _phase,
    chapterOf: chapterOf,
    session: widget.session,
    child: widget.child,
  );
}

class BookPagePaperScope extends InheritedWidget {
  const BookPagePaperScope({
    super.key,
    required this.count,
    required this.current,
    required this.info,
    required this.phase,
    required this.session,
    required this.chapterOf,
    required super.child,
  });
  final BookPageCounter? count;
  final SpreadPageRef? current;
  final PageInformation info;
  final ValueListenable<int> phase;
  final ReaderSession session;
  final int Function(ChapterLayout) chapterOf;

  static BookPagePaperScope? of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<BookPagePaperScope>();
    return scope?.count == null || scope?.current == null ? null : scope;
  }

  @override
  bool updateShouldNotify(BookPagePaperScope old) =>
      count != old.count ||
      current != old.current ||
      session != old.session ||
      info != old.info;

  Widget onPaper(Widget body, Size size, {SpreadPageRef? page}) => Stack(
    fit: StackFit.expand,
    children: [body, footerFor(page ?? current!, size.width)],
  );

  Widget curl(FoldFramesPainter paper, Size size, SpreadPageRef target) =>
      _CurlPageFooter(
        paper: paper,
        size: size,
        current: footerFor(current!, size.width),
        target: footerFor(target, size.width),
      );

  BookPageFooter footerFor(SpreadPageRef ref, double width) => BookPageFooter(
    count: count!,
    layout: ref.layout,
    page: ref.pageIndex,
    chapter: chapterOf(ref.layout),
    info: info,
    phase: phase,
    session: session,
    width: width,
  );
}

double _labelWidth(double width, double inset) =>
    (width / 2 - inset - 20).clamp(1, double.infinity);

class BookPageFooter extends StatelessWidget {
  const BookPageFooter({
    super.key,
    required this.count,
    required this.layout,
    required this.page,
    required this.chapter,
    required this.info,
    required this.phase,
    required this.session,
    required this.width,
  });
  final BookPageCounter count;
  final ChapterLayout layout;
  final int page, chapter;
  final PageInformation info;
  final ValueListenable<int> phase;
  final ReaderSession session;
  final double width;
  bool get loading => !count.complete && !count.failed;

  String? get label {
    if (!count.indexReady && loading) return null;
    if (count.failed) {
      final progress = session.readingProgressAt(
        chapter,
        layout.progressOfPage(page),
      );
      return '${(progress * 100).toStringAsFixed(2)}% · 页码未完成';
    }
    final n = count.number(chapter, layout, page);
    return '${n != null && n <= count.total ? n : '?'} / ${count.total}';
  }

  TextStyle get style => GtText.caption(
    info.color,
    family: info.fontFamily,
  ).copyWith(fontSize: 11);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: info.inset),
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.only(bottom: info.footerBottomPadding),
            child: SizedBox(
              // 固定布局和绘制边界，位数变化只重新排页脚中的文字。
              width: _labelWidth(width, info.inset),
              height: info.footerLineHeight,
              child: RepaintBoundary(
                child: ListenableBuilder(
                  listenable: count,
                  builder: (context, _) {
                    final text = label;
                    if (text == null) return const SizedBox.shrink();
                    return FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            text,
                            style: style,
                            textScaler: info.scaler,
                            maxLines: 1,
                          ),
                          if (loading) ...[
                            const SizedBox(width: 4),
                            SizedBox.square(
                              dimension: 9,
                              child: CustomPaint(
                                key: const ValueKey('book-page-count-mark'),
                                painter: _PageCountMark(info.color, phase),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
