import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/book_search.dart';
import '../../../../domain/repositories/book_search_repository.dart';
import '../../../../engine/search/search_text.dart';
import 'book_search_state.dart';
import 'book_search_navigation.dart';

final bookSearchProvider =
    NotifierProvider.family<BookSearchController, BookSearchState, String>(
      BookSearchController.new,
      isAutoDispose: true,
    );

class BookSearchController extends Notifier<BookSearchState> {
  BookSearchController(this.bookId);
  final String bookId;
  BookSearchRepository get _repository =>
      ref.read(bookSearchRepositoryProvider);
  Future<void>? _prefetching;
  BookSearchUpdate? _prepared;
  SearchCancellation _prefetch = SearchCancellation();
  SearchCancellation _query = SearchCancellation();
  int _version = 0;
  @override
  BookSearchState build() {
    ref.onDispose(() {
      _query.cancel();
      _prefetch.cancel();
    });
    return const BookSearchState();
  }

  void setQuery(String text) {
    cancelQuery();
    state = state.copyWith(
      query: text,
      cancelled: false,
      clearError: true,
      complete: false,
    );
    if (normalizeSearchQuery(text).isEmpty) {
      clear();
      return;
    }
    // 输入只更新待查询文字；按钮或键盘搜索键显式调用 search。
  }

  void clear() {
    cancelQuery();
    ref.read(bookSearchNavigationProvider(bookId).notifier).clearHighlight();
    state = const BookSearchState();
  }

  void cancelQuery() {
    _query.cancel();
    _prefetch.cancel();
    _prepared = null;
    _prefetching = null;
    ++_version;
    state = state.copyWith(busy: false, cancelled: true);
  }

  void close() {
    final running = state.busy;
    // 关闭页面取消前台查询，已完成查询的下一批仍可供结果导航使用。
    _query.cancel();
    if (running) ++_version;
    state = state.copyWith(busy: false, cancelled: running);
    if (!running && state.complete) state = state.copyWith(cancelled: false);
  }

  Future<void> search({bool more = false}) async {
    if (more &&
        (state.busy ||
            state.next == null ||
            state.resultQuery != state.query.trim())) {
      return;
    }
    if (more && _prepared != null) {
      _publishPrepared();
      return;
    }
    if (more && _prefetching != null) {
      final waitingVersion = _version, count = state.hits.length;
      state = state.copyWith(busy: true);
      await _prefetching;
      if (!ref.mounted ||
          waitingVersion != _version ||
          state.hits.length != count) {
        return;
      }
      if (_prepared != null) {
        _publishPrepared();
        return;
      }
    }
    _prefetch.cancel();
    _prepared = null;
    _prefetching = null;
    _query.cancel();
    final version = ++_version, token = _query = SearchCancellation();
    final text = state.query.trim(), cursor = more ? state.next : null;
    final prefix = more ? state.hits : const <BookSearchHit>[];
    if (normalizeSearchQuery(text).isEmpty) {
      clear();
      return;
    }
    state = state.copyWith(
      busy: true,
      clearError: true,
      cancelled: false,
      complete: more,
      scanned: more ? state.scanned : 0,
    );
    try {
      if (!ref.mounted || version != _version || token.cancelled) return;
      await for (final update in _repository.searchUpdates(
        bookId,
        text,
        after: cursor,
        limit: more ? 50 : 12,
        cancellation: token,
      )) {
        if (!ref.mounted || version != _version || token.cancelled) return;
        state = state.copyWith(scanned: update.scanned, total: update.total);
        // 首个新命中到达就替换旧词结果；零命中要等确实查完才能发布空态。
        if (update.page.hits.isNotEmpty || update.finished) {
          state = state.copyWith(
            resultQuery: text,
            hits: List.unmodifiable([...prefix, ...update.page.hits]),
            next: update.page.next,
            clearNext: update.page.next == null,
            busy: !update.finished,
            complete: true,
          );
        }
      }
      if (ref.mounted && version == _version && !token.cancelled) {
        _prepareMore();
      }
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '搜索正文失败');
      if (ref.mounted && version == _version && !token.cancelled) {
        state = state.copyWith(busy: false, error: '搜索失败：$error');
      }
    }
  }

  /// 用户浏览这一批时，只预先准备下一批；不提前生成全部列表或整书索引。
  void _prepareMore() {
    if (state.next == null || state.cancelled || _prefetching != null) return;
    final version = _version, text = state.resultQuery, cursor = state.next;
    final token = _prefetch = SearchCancellation();
    _prefetching = () async {
      try {
        await for (final update in _repository.searchUpdates(
          bookId,
          text,
          after: cursor,
          cancellation: token,
        )) {
          if (!ref.mounted || version != _version || token.cancelled) return;
          if (update.finished) _prepared = update;
        }
      } catch (_) {
        // 预取失败不影响当前列表，实际点击时走正常查询并展示原因。
      } finally {
        if (ref.mounted && version == _version) _prefetching = null;
      }
    }();
  }

  void _publishPrepared() {
    final update = _prepared!;
    _prepared = null;
    state = state.copyWith(
      hits: List.unmodifiable([...state.hits, ...update.page.hits]),
      next: update.page.next,
      clearNext: update.page.next == null,
      scanned: update.scanned,
      total: update.total,
      busy: false,
      complete: true,
      cancelled: false,
      clearError: true,
    );
    _prepareMore();
  }
}
