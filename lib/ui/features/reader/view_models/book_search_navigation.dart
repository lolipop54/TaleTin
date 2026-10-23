import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/book_search.dart';
import '../../../../domain/models/locator.dart';
import 'automatic_reading.dart';
import 'book_search_controller.dart';
import 'reader_session_view_model.dart';
import 'reader_view_model.dart';
import 'reader_progress_return.dart';
import 'original_layout_controller.dart';

const searchPreviewId = '__search_preview__';

class SearchNavigationState {
  const SearchNavigationState({
    this.origin,
    this.highlight,
    this.hit,
    this.busy = false,
    this.activeButton,
  });
  final Locator? origin;

  /// 仅作为绘制数据复用标注矩形管道；始终留在内存，不能交给标注仓库。
  final Annotation? highlight;
  final BookSearchHit? hit;
  final bool busy;

  /// 菜单按钮序号：0上一个、1返回、2下一个；只淡化本次操作。
  final int? activeButton;

  SearchNavigationState waiting(int? button) => SearchNavigationState(
    origin: origin,
    highlight: highlight,
    hit: hit,
    busy: true,
    activeButton: button,
  );
}

final bookSearchNavigationProvider =
    NotifierProvider.family<
      BookSearchNavigation,
      SearchNavigationState,
      String
    >(BookSearchNavigation.new, isAutoDispose: true);

class BookSearchNavigation extends Notifier<SearchNavigationState> {
  BookSearchNavigation(this.bookId);
  final String bookId;
  bool _stepping = false;
  @override
  SearchNavigationState build() => const SearchNavigationState();

  Future<void> _holdPage(Future<void> Function() jump) async {
    final transition = ref.read(readerProgressReturnProvider(bookId).notifier);
    await transition.prepareJumpCover?.call();
    final session = ref.read(readerSessionProvider(bookId)).value;
    final hold = ref.read(readerSessionProvider(bookId).notifier).usesOriginalWebView && session?.scrolling == false
        ? ref.read(originalLayoutProvider(bookId)).value?.holdPageDuringJump
        : null;
    if (hold != null) {
      await hold(jump);
    } else {
      await jump();
    }
    await transition.finishJumpCover?.call();
  }

  Future<void> open() async {
    ref.read(readerProgressReturnProvider(bookId).notifier).dismiss();
    await ref.read(automaticReadingProvider(bookId).notifier).discard();
    await ref
        .read(readerSessionProvider(bookId).notifier)
        .flushPendingPosition();
    if (!ref.mounted) return;
    state = SearchNavigationState(
      origin:
          state.origin ??
          ref.read(readerSessionProvider(bookId)).value?.currentAnchor,
      highlight: state.highlight,
      hit: state.hit,
    );
    ref.read(readerProvider.notifier).openPanel(ReaderPanel.search);
  }

  Annotation _target(
    SelectionRange range,
    String quote, {
    AnnotationColor? color,
  }) => Annotation(
    id: searchPreviewId,
    bookId: bookId,
    kind: AnnotationKind.highlight,
    start: range.start,
    end: range.end,
    quote: quote,
    color: color,
    createdAt: DateTime.utc(1970),
  );

  Future<void> pick(BookSearchHit hit) async {
    if (state.busy) return;
    await _pick(hit, state);
  }

  Future<void> _pick(
    BookSearchHit hit,
    SearchNavigationState old, {
    int? activeButton,
  }) async {
    state = old.waiting(activeButton);
    try {
      final book = await ref.read(bookRepositoryProvider).findById(bookId);
      if (book?.contentVersion != hit.contentVersion) {
        throw StateError('正文已经变化，请重新搜索');
      }
      await ref.read(automaticReadingProvider(bookId).notifier).discard();
      if (!ref.mounted) return;
      final origin =
          old.origin ??
          ref.read(readerSessionProvider(bookId)).value?.currentAnchor;
      final target = _target(
        hit.range,
        hit.context.substring(hit.matchStart, hit.matchEnd),
        color: AnnotationColor.blue,
      );
      await _holdPage(() async {
        state = SearchNavigationState(
          origin: origin,
          highlight: target,
          hit: hit,
          busy: true,
          activeButton: activeButton,
        );
        await ref
            .read(readerSessionProvider(bookId).notifier)
            .goToAnnotation(target, persistRelocation: false);
        if (ref.mounted) {
          state = SearchNavigationState(
            origin: origin,
            highlight: target,
            hit: hit,
          );
        }
      });
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '定位搜索结果失败');
      if (!ref.mounted) return;
      state = old;
      ref.read(readerProvider.notifier).showNotice('无法定位搜索结果：$error');
    }
  }

  Future<void> returnToOrigin() async {
    final origin = state.origin;
    if (origin == null || state.busy) return;
    final old = state;
    // 目标准备期间保留原菜单与高亮，完成返回后再移除。
    state = old.waiting(1);
    try {
      await ref.read(automaticReadingProvider(bookId).notifier).discard();
      await _holdPage(() async {
        await ref
            .read(readerSessionProvider(bookId).notifier)
            .goToAnnotation(
              _target(SelectionRange(start: origin, end: origin), ''),
              persistRelocation: false,
            );
        if (ref.mounted) state = const SearchNavigationState();
      });
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '返回搜索位置失败');
      if (!ref.mounted) return;
      state = old;
      ref.read(readerProvider.notifier).showNotice('无法返回搜索前位置：$error');
    }
  }

  void clearHighlight() => state = SearchNavigationState(origin: state.origin);

  /// 关闭搜索导航并留在当前真实落点，下一次搜索重新记下返回位置。
  void dismiss() {
    if (state.busy) return;
    state = const SearchNavigationState();
  }

  Future<void> step(int delta) async {
    if (state.busy || _stepping || state.hit == null) return;
    _stepping = true;
    final old = state;
    final activeButton = delta < 0 ? 0 : 2;
    // 追加搜索结果也属于这次点击，等待一开始就给对应按钮反馈。
    state = old.waiting(activeButton);
    final current = state.hit;
    try {
      var results = ref.read(bookSearchProvider(bookId));
      final index = results.hits.indexOf(current!);
      if (index < 0 || index + delta < 0) return;
      if (index + delta >= results.hits.length && results.next != null) {
        await ref.read(bookSearchProvider(bookId).notifier).search(more: true);
        if (!ref.mounted || state.hit != current) return;
        results = ref.read(bookSearchProvider(bookId));
      }
      if (index + delta < results.hits.length) {
        await _pick(
          results.hits[index + delta],
          old,
          activeButton: activeButton,
        );
      }
    } finally {
      _stepping = false;
      if (ref.mounted && state.busy) state = old;
    }
  }
}
