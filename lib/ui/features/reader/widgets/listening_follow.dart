import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/tts_state.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/services/listening_service.dart';
import '../view_models/listening_view_state.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
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

  @override
  void initState() {
    super.initState();
    // 立即保存服务引用；late 初始化表达式可能直到 dispose 才执行，届时 ref 已失效。
    _service = ref.read(listeningServiceProvider);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _visible = state == AppLifecycleState.resumed;
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
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _follow();
    });
  }

  void _follow() {
    if (!_visible || ref.read(readerSourceChangeProvider(widget.bookId))) return;
    final settings = ref.read(readerSettingsProvider(widget.bookId)).value;
    if (settings == null) return;
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    if (session == null) return;
    if (settings.settings.layoutMode.isOriginal && !session.scrolling) return;
    final layout = session.layout;
    if (_layout != layout) {
      _layout = layout;
      _requested = null;
    }
    _service.setPageBoundaries(
      this,
      session.scrolling || layout == null
          ? const []
          : [for (final page in layout.pages) layout.beginLocatorOf(page)],
    );
    final state = _service.snapshot;
    if (state.bookId != widget.bookId || !state.hasSession || !state.followReading) {
      _requested = null;
      ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .cancelSpeechFollow();
      return;
    }
    final target = state.status == TtsStatus.paused
        ? state.resumeLocator
        : state.confirmedLocator;
    if (target == null || _requested?.samePosition(target) == true) return;
    _requested = target;
    unawaited(
      ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .followSpeech(target)
          .catchError((Object error, StackTrace stack) {
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
    _service.setPageBoundaries(this, const []);
    _lifecycle.dispose();
    super.dispose();
  }
}
