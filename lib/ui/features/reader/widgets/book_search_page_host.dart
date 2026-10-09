import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../view_models/book_search_controller.dart';
import '../view_models/book_search_navigation.dart';
import '../view_models/reader_view_model.dart';
import 'panel_search.dart';
import 'reader_control_theme.dart';

/// 阅读页保留在下层；搜索独立成页，落点准备完后才退回正文。
class BookSearchPageHost extends ConsumerStatefulWidget {
  const BookSearchPageHost({super.key, required this.bookId});
  final String bookId;
  @override
  ConsumerState<BookSearchPageHost> createState() => _BookSearchPageHostState();
}

class _BookSearchPageHostState extends ConsumerState<BookSearchPageHost> {
  final _storage = PageStorageBucket();
  Route<void>? _route;

  void _dismissIfReady() {
    if (_route?.isCurrent == true &&
        ref.read(readerProvider).panel != ReaderPanel.search &&
        !ref.read(bookSearchNavigationProvider(widget.bookId)).busy) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _open() async {
    if (_route != null) return;
    final container = ProviderScope.containerOf(context);
    final route = PageRouteBuilder<void>(
      // 页面底色仍完全不透明；下层保持参与布局，原书 WebView 才能准备落点。
      opaque: false,
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => UncontrolledProviderScope(
        container: container,
        child: ReaderControlTheme(
          bookId: widget.bookId,
          child: PageStorage(
            bucket: _storage,
            child: PanelSearch(bookId: widget.bookId),
          ),
        ),
      ),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      ),
    );
    _route = route;
    await Navigator.of(context).push(route);
    if (!mounted) return;
    _route = null;
    ref.read(bookSearchProvider(widget.bookId).notifier).close();
    if (ref.read(readerProvider).panel == ReaderPanel.search) {
      ref.read(readerProvider.notifier).closePanel();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(readerProvider.select((s) => s.panel), (_, next) {
      if (next == ReaderPanel.search) {
        unawaited(_open());
      } else {
        _dismissIfReady();
      }
    });
    ref.listen(bookSearchNavigationProvider(widget.bookId), (_, next) {
      if (!next.busy) _dismissIfReady();
    });
    return const SizedBox.shrink();
  }
}
