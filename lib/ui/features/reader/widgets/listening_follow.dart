import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../core/diagnostics/listening_follow_diagnostics.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/services/listening_service.dart';
import '../view_models/listening_view_state.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/visible_spread.dart';
import '../view_models/reader_source_change.dart';

/// 简化 EPUB/TXT 共用跟随入口。后台不做布局，回到前台读取最新快照。
class ListeningFollow extends ConsumerStatefulWidget {
  const ListeningFollow({super.key, required this.bookId, required this.child});
  final String bookId;
  final Widget child;
  @override
  ConsumerState<ListeningFollow> createState() => _ListeningFollowState();
}

class _ListeningFollowState extends ConsumerState<ListeningFollow> {
  late final ListeningService _service;
  late final AppLifecycleListener _lifecycle;
  bool _visible = true;
  bool _scheduled = false;
  Locator? _requested;
  Object? _layout;
  final _diagnostics = ListeningFollowDiagnostics('standard');

  Map<String, Object?> _snapshot() {
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    final target = _service.snapshot.pageFollowLocator;
    return {
      ...listeningDiagnosticSnapshot(
        _service.snapshot,
        readerBookId: widget.bookId,
        anchor: session?.currentAnchor,
      ),
      'visible': _visible,
      'mounted': mounted,
      'scheduled': _scheduled,
      'hasSettings':
          ref.read(readerSettingsProvider(widget.bookId)).value != null,
      'hasSessionData': session != null,
      'scrolling': session?.scrolling,
      'chapter': session?.chapterIndex,
      'page': session?.pageIndex,
      'targetChapter': session?.chapters.indexWhere(
        (c) => c.id == target?.chapterId,
      ),
      'sameRequestedTarget':
          target != null && _requested?.samePosition(target) == true,
      'hasLayout': session?.layout != null,
    };
  }

  @override
  void initState() {
    super.initState();
    // 立即保存服务引用；late 初始化表达式可能直到 dispose 才执行，届时 ref 已失效。
    _service = ref.read(listeningServiceProvider);
    _diagnostics.lifecycle('attached', _snapshot());
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _visible = state == AppLifecycleState.resumed;
        if (_service.snapshot.bookId == widget.bookId) {
          _diagnostics.lifecycle(state.name, _snapshot(), snapshot: _snapshot);
        }
        if (!_visible) {
          _service.setPageBoundaries(this, const []);
          ref
              .read(readerSessionProvider(widget.bookId).notifier)
              .cancelSpeechFollow();
        } else {
          _requested = null;
          _schedule();
        }
      },
    );
  }

  void _schedule() {
    if (_scheduled) {
      _diagnostics.step('scheduleSkip', {'reason': 'alreadyScheduled'});
      return;
    }
    _scheduled = true;
    _diagnostics.step('frameQueued', {'visible': _visible});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _diagnostics.step('frameCallback', {
        'mounted': mounted,
        'visible': _visible,
      });
      if (mounted) _follow();
    });
  }

  void _follow() {
    if (!_visible || ref.read(readerSourceChangeProvider(widget.bookId))) {
      _diagnostics.step('skip', {
        'reason': !_visible ? 'background' : 'sourceChanging',
      });
      return;
    }
    final settings = ref.read(readerSettingsProvider(widget.bookId)).value;
    if (settings == null) {
      _diagnostics.step('skip', {'reason': 'settingsNotReady'});
      return;
    }
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    if (session == null) {
      _diagnostics.step('skip', {'reason': 'sessionNotReady'});
      return;
    }
    // TXT可能继承“原书”偏好，但实际正文仍是简化排版，必须由这里跟随。
    // 与正文显示器使用同一判断，只有真正使用原书分页时才交给它处理。
    if (settings.settings.layoutMode.isOriginal &&
        session.book.format.supportsOriginalLayout &&
        !session.scrolling) {
      _diagnostics.step('skip', {'reason': 'originalRendererOwnsFollow'});
      return;
    }
    final layout = session.layout;
    if (_layout != layout?.identity) {
      _layout = layout?.identity;
      _requested = null;
    }
    _service.setPageBoundaries(
      this,
      session.scrolling || layout == null
          ? const []
          : [for (final page in layout.pages) layout.beginLocatorOf(page)],
    );
    final state = _service.snapshot;
    final target = state.bookId == widget.bookId
        ? state.pageFollowLocator
        : null;
    _diagnostics.step('check', {
      if (_diagnostics.observing) ..._snapshot(),
      'status': state.status.name,
      'hasTarget': target != null,
      'chapter': session.chapterIndex,
      'page': session.pageIndex,
      'targetChapter': session.chapters.indexWhere(
        (c) => c.id == target?.chapterId,
      ),
      'targetOffset': target?.utf16Offset,
    });
    if (target == null) {
      _requested = null;
      ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .cancelSpeechFollow();
      return;
    }
    if (_requested?.samePosition(target) == true) {
      _diagnostics.step('skip', {'reason': 'sameRequestedTarget'});
      return;
    }
    _requested = target;
    if (settings.settings.spreadEnabled &&
        spreadContains(
          ref.read(visibleSpreadProvider(widget.bookId)),
          target,
        )) {
      _diagnostics.step('skip', {'reason': 'targetInVisibleSpread'});
      return;
    }
    unawaited(
      ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .followSpeech(target, diagnostics: _diagnostics)
          .then((_) {
            if (!mounted) return;
            final current = ref
                .read(readerSessionProvider(widget.bookId))
                .value;
            _diagnostics.step('followReturned', {
              ..._snapshot(),
              'visible': _visible,
              'chapter': current?.chapterIndex,
              'page': current?.pageIndex,
            });
          })
          .catchError((Object error, StackTrace stack) {
            _diagnostics.step('followError', {
              'type': error.runtimeType.toString(),
            });
            if (mounted) {
              ref
                  .read(readerSessionProvider(widget.bookId).notifier)
                  .reportPositionFailure(error, stack);
            }
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(listeningViewStateProvider);
    ref.watch(readerSessionProvider(widget.bookId));
    ref.watch(readerSettingsProvider(widget.bookId));
    _schedule();
    return widget.child;
  }

  @override
  void dispose() {
    _diagnostics.step('disposed', {
      'visible': _visible,
      'scheduled': _scheduled,
    });
    _diagnostics.dispose();
    _service.setPageBoundaries(this, const []);
    _lifecycle.dispose();
    super.dispose();
  }
}
