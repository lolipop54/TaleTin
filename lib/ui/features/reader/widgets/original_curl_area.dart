import 'dart:ui' as ui;
import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../../../../domain/models/reading_settings.dart';
import '../../../../core/diagnostics/reader_recovery_diagnostics.dart';
import '../../../../core/diagnostics/reader_turn_state_diagnostics.dart';
import 'fold_frames.dart';
import 'original_host_controller.dart';
import 'original_preload_gate.dart';
import 'page_information.dart';
import 'page_turn_area.dart';
import 'turn_trace.dart';
import 'book_paper.dart';

part 'original_page_images.dart';

/// 原书折页的目标页；页序仅用于本次动画，阅读位置仍由会话保存。
typedef OriginalTurnTarget = ({
  OriginalHostController host,
  int page,
  int chapter,
  PageInformation? information,
});
typedef _PageKey = (OriginalHostController, int, int);

class OriginalCurlArea extends StatefulWidget {
  const OriginalCurlArea({
    super.key,
    required this.host,
    required this.resolve,
    required this.commit,
    required this.onCenterTap,
    required this.onError,
    required this.paper,
    this.information,
    this.captureRevision,
    this.beforeTurn,
    this.preload,
    this.spread = false,
    this.bookEdges = false,
    this.onImageTap,
    this.viewportOrigin = Offset.zero,
    this.effect = PageTurnEffect.curl,
    this.prefetchEnabled = true,
    this.captureVersions = const {},
    this.positionRevision,
    this.prefetchResolve,
  });
  final Future<bool> Function()? beforeTurn;
  final bool spread, bookEdges;
  final OriginalPreloadGate? preload;
  final Future<bool> Function(Offset)? onImageTap;
  final Offset viewportOrigin;
  final Object? positionRevision;
  final PageTurnEffect effect;

  /// 控制栏打开时先让章节定位与排版使用主线程，收起后再补翻页截图。
  final bool prefetchEnabled;
  final Future<OriginalTurnTarget?> Function(bool backward)? prefetchResolve;
  final Map<OriginalHostController, int> captureVersions;
  final Object? captureRevision;
  final PageInformation? information;
  final OriginalHostController? host;
  final Future<OriginalTurnTarget?> Function(bool backward) resolve;
  final Future<bool> Function(OriginalTurnTarget target) commit;
  final VoidCallback onCenterTap;
  final ValueChanged<String> onError;
  final Color paper;
  @override
  State<OriginalCurlArea> createState() => OriginalCurlAreaState();
}

class OriginalCurlAreaState extends State<OriginalCurlArea> {
  final _inputKey = GlobalKey();
  Future<void> turn(bool forward) => PageTurnArea.turn(_inputKey, forward);
  ui.Image? _cover, _landing;
  OriginalTurnTarget? _target;
  int _turn = 0;
  bool _failed = false;
  final _pages = <_PageKey, ui.Image>{};
  final _paintedPages =
      <(_PageKey, Object?, Color, bool, bool, Size), ui.Image>{};
  final _nativeInformationVersions = <_PageKey, Object>{};
  final _directions = <(_PageKey, bool), OriginalTurnTarget>{};
  (OriginalHostController, int)? _knownPage;
  ui.Image? _warmCover;
  _PageKey _pageKey(OriginalHostController host, int page) =>
      (host, page, widget.captureVersions[host] ?? 0);
  Future<void>? _priming;
  bool _primeAgain = false;
  int _generation = 0;
  bool _active = false;
  bool _lastBackward = false;
  bool? _wantedBackward;
  ({
    OriginalHostController origin,
    int page,
    int generation,
    OriginalTurnTarget target,
  })?
  _held;
  Future<void>? _presentTarget;
  Future<void> Function()? _pendingPresentation;
  Future<void>? _restoring;

  Future<void> _showTarget(
    OriginalHostController origin,
    int page,
    OriginalTurnTarget target,
  ) async {
    if (_held?.target.host == target.host &&
        _held?.target.page == target.page) {
      return;
    }
    _held = (
      origin: origin,
      page: page,
      generation: _generation,
      target: target,
    );
    await target.host.holdPage(target.page);
  }

  Future<void> _restoreHeld() => _restoring ??= () async {
    _pendingPresentation = null;
    try {
      await _presentTarget;
    } catch (_) {
      /* 失败的定位也需要撤回临时显示槽。 */
    }
    final held = _held;
    if (held == null) return;
    if (held.generation == _generation && held.origin == held.target.host) {
      await held.origin.previewPage(held.page);
    }
    await held.target.host.releaseHeldPage();
    if (identical(_held, held)) _held = null;
    traceTurn('preview restored page=${held.page}');
  }().whenComplete(() => _restoring = null);

  Future<void> _cancelTurn() async {
    _wantedBackward = null;
    // 热页拖动可先于后台查询开始；取消仍需等后台停止，避免还原后又被预览改页。
    await _priming;
    await _restoreHeld();
    if (!mounted) return;
    widget.preload?.release(this);
    widget.preload?.requestChapter(null);
    setState(_release);
    _prime();
  }

  bool _interruptPriming = false;
  void resumePrefetch() {
    if (widget.preload?.turnPreparationBlocked == true) return;
    _prime();
    // 安静窗口结束时可能没有其它重绘，主动安排一帧才能执行补图回调。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 等预取恢复原页后再取图，不能截到后台临时预览的前后页。
  Future<ui.Image> captureVisiblePage() async {
    _interruptPriming = true;
    await _priming;
    if (!mounted || _active) throw StateError('页面仍在翻动');
    final host = widget.host!;
    final size = context.size!;
    final image = await _pageImage(
      host,
      await host.page,
      widget.information,
      size,
    );
    if (!mounted) {
      image.dispose();
      throw StateError('阅读页已关闭');
    }
    return image;
  }

  /// 听书定位前等待正在预览的临时页还原，再使所有旧截图与手势失效。
  Future<void> settleForSpeech({bool invalidatePages = true}) async {
    _interruptPriming = true;
    await _priming;
    await _restoreHeld();
    if (!mounted) return;
    setState(() {
      // 模式切换只需停止手势，保留确认过的原页截图；听书跳转仍使旧图失效。
      if (invalidatePages) _clearPages();
      _release();
      _turn++;
    });
  }

  void _clearPages() {
    _wantedBackward = null;
    _generation++;
    for (final image in _pages.values) {
      image.dispose();
    }
    _pages.clear();
    for (final image in _paintedPages.values) {
      image.dispose();
    }
    _paintedPages.clear();
    _nativeInformationVersions.clear();
    _directions.clear();
    _knownPage = null;
  }

  void _prime() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final host = widget.host;
      if (!mounted ||
          !widget.prefetchEnabled ||
          widget.preload?.turnPreparationBlocked == true ||
          _active ||
          host == null ||
          widget.information == null) {
        return;
      }
      if (_priming != null) {
        _primeAgain = true;
        return;
      }
      final generation = _generation;
      traceTurn(
        'prime begin host=${identityHashCode(host)} generation=$generation',
      );
      _interruptPriming = false;
      _priming = () async {
        try {
          final page = await host.page;
          if (!mounted ||
              generation != _generation ||
              _interruptPriming ||
              widget.preload?.turnPreparationBlocked == true) {
            return;
          }
          _knownPage = (host, page);
          final image = await _pageImage(
            host,
            page,
            widget.information,
            context.size!,
          );
          if (!mounted || generation != _generation) {
            image.dispose();
            return;
          }
          if (_active ||
              !widget.prefetchEnabled ||
              widget.prefetchResolve == null) {
            image.dispose();
            return;
          }
          setState(() => _warmCover = image);
          await WidgetsBinding.instance.endOfFrame;
          for (final backward in [_lastBackward, !_lastBackward]) {
            if (_interruptPriming ||
                _active ||
                !mounted ||
                !widget.prefetchEnabled ||
                widget.preload?.turnPreparationBlocked == true ||
                generation != _generation) {
              break;
            }
            await _warmTarget(
              host,
              page,
              backward,
              () => widget.prefetchResolve!(backward),
            );
          }
        } catch (error) {
          traceTurn('prime failed type=${error.runtimeType}');
        } finally {
          traceTurn(
            'prime end host=${identityHashCode(host)} interrupted=$_interruptPriming active=$_active again=$_primeAgain',
          );
          _priming = null;
          final cover = _warmCover;
          _warmCover = null;
          if (mounted) setState(() {});
          WidgetsBinding.instance.addPostFrameCallback((_) => cover?.dispose());
          // 定位期间旧预取尚未结束时，新预取会被合并；结束后补做最新页。
          if (mounted && (generation != _generation || _primeAgain)) {
            _primeAgain = false;
            _prime();
          }
        }
      }();
    });
  }

  Future<void> _warmTarget(
    OriginalHostController host,
    int page,
    bool backward,
    Future<OriginalTurnTarget?> Function() resolve,
  ) async {
    final generation = _generation;
    final target = await resolve();
    if (target == null || !mounted || generation != _generation) return;
    // 查询目标期间可能已有手指按下；在取下一张后台截图之前再确认一次。
    if (_interruptPriming ||
        _active ||
        widget.preload?.turnPreparationBlocked == true) {
      traceTurn(
        'prefetch yield before-capture chapter=${target.chapter} page=${target.page}',
      );
      return;
    }
    final previewed = !_hasPage(target.host, target.page, target.information);
    // 先补阅读方向的直接下一页。反方向已缓存的来路照常复用，缺图时
    // 等120ms安静窗口结束，避免真实点按卡在无关的第二张截图后面。
    if (previewed &&
        backward != _lastBackward &&
        widget.preload?.blocked == true) {
      traceTurn(
        'prefetch defer reverse chapter=${target.chapter} page=${target.page}',
      );
      return;
    }
    var captured = false;
    final size = context.size!;
    try {
      if (previewed) await (_presentTarget = _showTarget(host, page, target));
      (await _pageImage(
        target.host,
        target.page,
        target.information,
        size,
      )).dispose();
      captured = true;
      if (mounted && generation == _generation) {
        _directions[(_pageKey(host, page), backward)] = target;
      }
    } finally {
      if (previewed) {
        final adopt =
            captured &&
            mounted &&
            generation == _generation &&
            _active &&
            _wantedBackward == backward;
        if (adopt) {
          // 正在取的就是用户要翻的一页，保留位置与旧图遮盖，直接交给前台。
          _cover?.dispose();
          _cover = _warmCover?.clone();
          traceTurn(
            'prefetch adopted chapter=${target.chapter} page=${target.page}',
          );
        } else {
          await _restoreHeld();
        }
      }
    }
  }

  OriginalTurnTarget _freshInformation(OriginalTurnTarget target) {
    final old = target.information, now = widget.information;
    if (old == null || now == null) return target;
    return (
      host: target.host,
      page: target.page,
      chapter: target.chapter,
      information: PageInformation(
        chapter: old.chapter,
        book: old.book,
        progress: old.progress,
        clock: now.clock,
        battery: now.battery,
        inset: now.inset,
        bottomInset: now.bottomInset,
        color: now.color,
        scaler: now.scaler,
        visible: now.visible,
        searchMenu: null,
        fontFamily: now.fontFamily,
        bookmarked: old.bookmarked,
        bookEdges: now.bookEdges,
        spread: now.spread,
        spreadSide: now.spreadSide,
        paper: now.paper,
        backgroundImage: now.backgroundImage,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    ReaderTurnStateDiagnostics.attach(
      this,
      'originalTurn',
      () => {
        'mounted': mounted,
        'active': _active,
        'failed': _failed,
        'generation': _generation,
        'priming': _priming != null,
        'restoring': _restoring != null,
        'presentTargetStored': _presentTarget != null,
        'presentationStored': _pendingPresentation != null,
        'held': _held != null,
        'cover': _cover != null,
        'landing': _landing != null,
        'warmCover': _warmCover != null,
        'cachedPages': _pages.length,
        'paintedPages': _paintedPages.length,
        'targetPage': _target?.page,
        'targetChapter': _target?.chapter,
        'knownPage': _knownPage?.$2,
      },
    );
    widget.preload?.addListener(resumePrefetch);
    _prime();
  }

  @override
  void didUpdateWidget(OriginalCurlArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    final positionChanged =
        !_active && oldWidget.positionRevision != widget.positionRevision;
    // 本次翻页把预载宿主接到前台时，正文截图仍有效，不能重新截图章首页。
    final handedOver = _active && _target?.host == widget.host;
    if (ReaderRecoveryDiagnostics.observing &&
        (oldWidget.captureRevision != widget.captureRevision ||
            positionChanged ||
            oldWidget.host != widget.host)) {
      ReaderRecoveryDiagnostics.record('turnCacheRevision', {
        'active': _active,
        'captureChanged': oldWidget.captureRevision != widget.captureRevision,
        'positionChanged': positionChanged,
        'hostChanged': oldWidget.host != widget.host,
        'handedOver': handedOver,
        'cachedPages': _pages.length,
      });
    }
    if (oldWidget.captureRevision != widget.captureRevision ||
        (oldWidget.host != widget.host && !handedOver) ||
        positionChanged) {
      traceTurn(
        'invalidate active=$_active revision=${oldWidget.captureRevision != widget.captureRevision} host=${oldWidget.host != widget.host} position=$positionChanged',
      );
      _clearPages();
      unawaited(_cancelTurn());
    }
    if (oldWidget.captureRevision != widget.captureRevision ||
        oldWidget.host != widget.host ||
        (oldWidget.information == null && widget.information != null) ||
        (!oldWidget.prefetchEnabled && widget.prefetchEnabled) ||
        positionChanged ||
        !mapEquals(oldWidget.captureVersions, widget.captureVersions)) {
      _prime();
    }
  }

  void _release() {
    _active = false;
    _pendingPresentation = null;
    final cover = _cover, landing = _landing;
    _cover = null;
    _landing = null;
    _target = null;
    // RawImage 已在上一帧使用这些句柄，移除后再释放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      cover?.dispose();
      landing?.dispose();
    });
  }

  Future<FoldFrames?> _prepare(PageTurnDirection direction) async {
    ReaderRecoveryDiagnostics.record('turnPrepare', {
      'direction': direction.name,
      'cachedPages': _pages.length,
      'paintedPages': _paintedPages.length,
      'generation': _generation,
      'host': widget.host == null ? null : identityHashCode(widget.host!),
    });
    widget.preload?.hold(this);
    final backward = direction == PageTurnDirection.backward;
    _wantedBackward = backward;
    _active = true;
    _interruptPriming = true;
    final generation = _generation;
    final watch = Stopwatch()..start();
    ui.Image? current, next;
    _failed = false;
    try {
      if (await traceTurnStep(
                'prepare manual-handoff',
                () async => widget.beforeTurn?.call(),
              ) ==
              false ||
          !mounted) {
        return null;
      }
      // 两张原尺寸图已齐备时，后台邻页查询不应挡住跟手绘制。
      // 真正的网页交接仍在_commit等待；取消也先等待后台退出再还原。
      if (!_hasTurnImages(backward)) {
        await traceTurnStep('prepare wait-current-prefetch', () async {
          await _priming;
        });
      }
      if (!mounted || generation != _generation) return null;
      final host = widget.host;
      if (host == null) return null;
      final known = _knownPage;
      final ready = known?.$1 == host
          ? _directions[(_pageKey(host, known!.$2), backward)]
          : null;
      final destination = ready == null
          ? await traceTurnStep(
              'prepare resolve-target',
              () => widget.resolve(backward),
            )
          : _freshInformation(ready);
      if (destination == null || !mounted || generation != _generation) {
        return null;
      }
      final page = known?.$1 == host ? known!.$2 : await host.page;
      _knownPage = (host, page);
      if (!mounted || generation != _generation) return null;
      final size = context.size!;
      current = await traceTurnStep<ui.Image>(
        'prepare current-image',
        () => _pageImage(host, page, widget.information, size),
      );
      if (!mounted || generation != _generation) return null;
      final hot = _hasPage(
        destination.host,
        destination.page,
        destination.information,
      );
      _cover?.dispose();
      setState(() => _cover = current!.clone());
      // 缓存命中时先只画两张图，避免网页切页的Android/GPU绘制与动画争抢时间。
      // 冷页仍先定位截图，准备完成前保留旧页；热页在动画结束后由目标图遮盖交接。
      Future<void> presentation() async {
        if (_held == null) await WidgetsBinding.instance.endOfFrame;
        if (!mounted || generation != _generation) return;
        await _showTarget(host, page, destination);
      }

      _presentTarget = null;
      _pendingPresentation = hot ? presentation : null;
      if (!hot) {
        await traceTurnStep(
          'prepare target-presentation',
          () => _presentTarget = presentation(),
        );
      }
      next = await traceTurnStep<ui.Image>(
        'prepare target-image',
        () => _pageImage(
          destination.host,
          destination.page,
          destination.information,
          size,
        ),
      );
      if (!mounted || generation != _generation) return null;
      _target = destination;
      _landing = next.clone();
      traceTurn(
        'prepared retained hot=$hot target=${destination.chapter}/${destination.page} us=${watch.elapsedMicroseconds}',
      );
      final frames = widget.spread
          ? FoldFrames.spread(
              current,
              next,
              size,
              backward: backward,
              paper: widget.paper,
              backgroundImage: widget.information?.backgroundImage,
              edges: widget.bookEdges,
            )
          : FoldFrames.images(
              current,
              next,
              size,
              backward: backward,
              paper: widget.paper,
              backgroundImage: widget.information?.backgroundImage,
              bookEdges: widget.bookEdges,
            );
      current = null;
      next = null;
      return frames;
    } catch (error) {
      traceTurn('prepare error type=${error.runtimeType}');
      _failed = true;
      if (mounted && generation == _generation) {
        widget.onError('页面图像准备失败，请重试翻页');
      }
      return null;
    } finally {
      current?.dispose();
      next?.dispose();
      if (_target == null) await _cancelTurn();
    }
  }

  Future<bool> _commit(PageTurnDirection direction) async {
    final target = _target;
    traceTurn(
      'commit target=${target?.chapter}/${target?.page} failed=$_failed',
    );
    if (target == null || _failed) return false;
    _interruptPriming = true;
    final generation = _generation;
    await _priming;
    try {
      final presentation = _pendingPresentation;
      _pendingPresentation = null;
      if (presentation != null) _presentTarget = presentation();
      await _presentTarget;
    } catch (_) {
      return false;
    }
    if (!mounted || _failed || generation != _generation) return false;
    // 目标截图一直盖到 WebView 已经显示同一页，避免末帧闪回旧页。
    setState(() {
      _cover?.dispose();
      _cover = _landing?.clone();
    });
    final moved = await traceTurnStep(
      'commit chapter=${target.chapter} page=${target.page}',
      () => widget.commit(target),
    );
    if (!mounted || generation != _generation) return false;
    if (!moved) {
      // 提交被业务层拒绝时也属于取消，不能只撤遮盖而留下预览目标。
      await _restoreHeld();
      return false;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation) return false;
    await target.host.releaseHeldPage(committed: true);
    _held = null;
    _wantedBackward = null;
    if (!mounted) return false;
    if (moved) {
      _lastBackward = direction == PageTurnDirection.backward;
      setState(() {
        _knownPage = (target.host, target.page);
        _turn++;
        _release();
      });
      // 成功翻页由 turnId 复位，不经过取消路径的 onGestureFinished。
      // 必须在目标已上屏后自行释放，否则远端补载会一直暂停。
      widget.preload?.release(this);
      widget.preload?.requestChapter(null);
      // 原生 WebView 截图占用 Android 主线程，等动画结束再准备后续页，
      // 避免大图片的绘制和像素传输打断短促的点按翻页动画。
      _prime();
    }
    return moved;
  }

  @override
  void dispose() {
    ReaderTurnStateDiagnostics.detach(this);
    unawaited(_restoreHeld());
    widget.preload?.removeListener(resumePrefetch);
    widget.preload?.release(this);
    _clearPages();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageTurnArea(
    key: _inputKey,
    spread: widget.spread,
    slideImages: true,
    effect: widget.effect,
    turnId: _turn,
    traceLabel: 'original',
    currentPage: (_cover ?? _warmCover) == null
        ? widget.effect == PageTurnEffect.slide
              ? const SizedBox.expand()
              : CustomPaint(
                  painter: _InformationPainter(
                    widget.information,
                    widget.paper,
                    widget.bookEdges,
                    widget.spread,
                  ),
                )
        : RawImage(image: _cover ?? _warmCover, fit: BoxFit.fill),
    previousPage: const SizedBox.expand(),
    nextPage: const SizedBox.expand(),
    prepareFold: _prepare,
    onTurn: _commit,
    onCenterTap: () {
      _active = false;
      widget.preload?.release(this);
      widget.onCenterTap();
    },
    onInteractionStart: () {
      _interruptPriming = true;
      _active = true;
    },
    onTapIntercept: (point) async {
      _interruptPriming = true;
      // 点按先停止后续预取并还原当前页，再判断图像／链接。不能为了接管
      // 正在截图的邻页，拿被临时预览的目标页做命中判断。
      _wantedBackward = null;
      await traceTurnStep('tap wait-prefetch', () async {
        await _priming;
      });
      // 松手已被判定为点击。网页可能在 activateLink 返回前上报链接，
      // 此时上层要截旧页；不能仍把这次点击当作正在拖动而拒绝截图。
      _active = false;
      if (await widget.onImageTap?.call(point) == true) {
        _active = false;
        widget.preload?.release(this);
        _clearPages();
        return true;
      }
      final linked = widget.onImageTap == null
          ? await widget.host?.activateLink(point - widget.viewportOrigin) ??
                false
          : false;
      if (linked) {
        _active = false;
        widget.preload?.release(this);
        // 链接的最终位置由宿主页回报后再预取；此刻重载会拿旧页并覆盖目标页。
        _clearPages();
      }
      return linked;
    },
    onGestureFinished: _cancelTurn,
    inputRevision: widget.captureRevision,
  );
}

class _InformationPainter extends CustomPainter {
  const _InformationPainter(
    this.information,
    this.paper,
    this.edges,
    this.spread,
  );
  final PageInformation? information;
  final Color paper;
  final bool edges, spread;
  @override
  void paint(Canvas canvas, Size size) {
    if (edges || spread) {
      BookPaperPainter(
        paper,
        edges: edges,
        spread: spread,
        decorationOnly: true,
        backgroundImage: information?.backgroundImage,
      ).paint(canvas, size);
    }
    information?.paint(canvas, size);
  }

  @override
  bool shouldRepaint(_InformationPainter old) =>
      old.information != information ||
      old.paper != paper ||
      old.edges != edges ||
      old.spread != spread;
}
