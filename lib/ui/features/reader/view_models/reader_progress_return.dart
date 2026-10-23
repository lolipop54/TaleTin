import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/diagnostics/reader_work_trace.dart';

import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/locator.dart';
import 'automatic_reading.dart';
import 'book_search_navigation.dart';
import 'original_layout_controller.dart';
import 'reader_session_view_model.dart';
import 'reader_view_model.dart';

class ReaderProgressReturnState {
  const ReaderProgressReturnState({
    this.origin,
    this.busy = false,
    this.fromSlider = false,
  });
  final Locator? origin;
  final bool busy, fromSlider;
}

final readerProgressReturnProvider = NotifierProvider.autoDispose
    .family<ReaderProgressReturn, ReaderProgressReturnState, String>(
      ReaderProgressReturn.new,
    );

/// 只记最近一次目录／书签／笔记跳转前的正文锚点，不写入书库。
class ReaderProgressReturn extends Notifier<ReaderProgressReturnState> {
  ReaderProgressReturn(this.bookId);
  final String bookId;
  int _seekVersion = 0;

  /// 阅读层先把完整旧页盖住；位置请求必须在遮盖真正上屏后再执行。
  Future<void> Function()? prepareJumpCover;
  Future<void> Function()? finishJumpCover;

  /// 上下章只改变位置，不创建“返回原进度”，但仍等待完整交接。
  Future<void> transition(Future<void> Function() action) async {
    if (state.busy) return;
    final previous = state;
    state = ReaderProgressReturnState(
      origin: previous.origin,
      fromSlider: previous.fromSlider,
      busy: true,
    );
    try {
      await prepareJumpCover?.call();
      await action();
    } finally {
      if (ref.mounted) {
        state = previous;
        await finishJumpCover?.call();
      }
    }
  }

  @override
  ReaderProgressReturnState build() => const ReaderProgressReturnState();

  /// 一次打开控制面板期间只记第一次调整前的位置。
  void beginSlider() {
    if (state.fromSlider || state.busy) return;
    state = ReaderProgressReturnState(
      fromSlider: true,
      origin: ref.read(readerSessionProvider(bookId)).value?.currentAnchor,
    );
  }

  Future<void> seek(Future<void> Function() action) async {
    final version = ++_seekVersion;
    final trace = !readerWorkTraceEnabled
        ? null
        : ReaderWorkTrace.start('reader.progress.transition', {
            'bookId': bookId,
            'request': version,
          });
    var status = 'incomplete';
    beginSlider();
    final previous = state;
    state = ReaderProgressReturnState(
      origin: previous.origin,
      fromSlider: true,
      busy: true,
    );
    try {
      await prepareJumpCover?.call();
      trace?.mark('old_page_cover');
      // 截旧页可能比下一次拖动慢；旧调用不得在最后一次选择之后才提交位置。
      if (!ref.mounted || version != _seekVersion) return;
      await action();
      trace?.mark('target_position');
      status = 'ok';
    } finally {
      if (ref.mounted && version == _seekVersion) {
        state = ref.read(readerProvider).controlsVisible
            ? ReaderProgressReturnState(
                origin: previous.origin,
                fromSlider: true,
              )
            : const ReaderProgressReturnState();
        await finishJumpCover?.call();
      }
      trace?.mark('reveal_animation');
      trace?.finish(status: version == _seekVersion ? status : 'superseded');
    }
  }

  void pageChanged() {
    if (!state.fromSlider) dismiss();
  }

  void controlsClosed() {
    if (state.fromSlider) {
      _seekVersion++;
      state = const ReaderProgressReturnState();
    }
  }

  Future<void> jump(Future<void> Function() action) async {
    if (state.busy) return;
    final previous = state;
    final origin = ref.read(readerSessionProvider(bookId)).value?.currentAnchor;
    state = ReaderProgressReturnState(origin: previous.origin, busy: true);
    try {
      await prepareJumpCover?.call();
      await action();
      if (!ref.mounted) return;
      // 普通跳转结束搜索预览，避免两种菜单和旧搜索高亮一起出现。
      ref.read(bookSearchNavigationProvider(bookId).notifier).dismiss();
      state = ReaderProgressReturnState(origin: origin);
      await finishJumpCover?.call();
    } catch (_) {
      if (ref.mounted) state = previous;
      rethrow;
    }
  }

  Future<void> returnToOrigin() async {
    final previous = state;
    final origin = previous.origin;
    if (origin == null || previous.busy) return;
    state = ReaderProgressReturnState(
      origin: origin,
      busy: true,
      fromSlider: previous.fromSlider,
    );
    try {
      await ref.read(automaticReadingProvider(bookId).notifier).discard();
      await prepareJumpCover?.call();
      final session = ref.read(readerSessionProvider(bookId).notifier);
      Future<void> jump() => session.goToAnnotation(
        Annotation(
          id: '__progress_return__',
          bookId: bookId,
          kind: AnnotationKind.highlight,
          start: origin,
          end: origin,
          quote: '',
          createdAt: DateTime.utc(1970),
        ),
        persistRelocation: false,
      );
      // 复用精确落点流程，原书保留旧画面直到目标就绪；临时范围不保存为笔记。
      final hold = session.usesOriginalWebView
          ? ref.read(originalLayoutProvider(bookId)).value?.holdPageDuringJump
          : null;
      if (hold == null) {
        await jump();
      } else {
        await hold(jump);
      }
      if (ref.mounted) {
        state = const ReaderProgressReturnState();
        await finishJumpCover?.call();
      }
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '返回阅读位置失败');
      if (!ref.mounted) return;
      state = previous;
      ref.read(readerProvider.notifier).showNotice('无法返回原进度，请重试');
    }
  }

  void dismiss() {
    if (!state.busy) state = const ReaderProgressReturnState();
  }
}
