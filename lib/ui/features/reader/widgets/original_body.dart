/// 原书分页：一个 WebView 承载三个固定的章节 iframe。
library;

import 'package:taletin/core/diagnostics/app_errors.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../platform/channels/reading_fonts.dart';
import '../../../core/theme/reading_background_texture.dart';
import '../../../../platform/channels/original_webview_warmup.dart';
import '../../../../core/diagnostics/opening_experiments.dart';
import '../../../../core/diagnostics/reader_delivery_experiments.dart';
import '../../../../core/diagnostics/bookmark_trace.dart';
import '../../../../core/diagnostics/reader_turn_diagnostics.dart';
import '../../../../core/diagnostics/reader_recovery_diagnostics.dart';
import '../../../../data/services/epub_source_repository.dart';
import 'original_host_controller.dart';
import 'original_font_assets.dart';
import 'original_console_errors.dart';
import 'original_page_capture.dart';
import 'original_preload_gate.dart';
import 'turn_trace.dart';

part 'original_chapter.dart';
part 'original_body_resources.dart';
part 'original_body_messages.dart';
part 'original_initial_layout.dart';

const String kFrameworkPathPrefix = '/__gt__/';

class OriginalBody extends StatefulWidget {
  const OriginalBody({
    super.key,
    required this.session,
    required this.chapters,
    required this.current,
    required this.slide,
    required this.preload,
    this.prepareOnDemand = true,
  });
  final EpubSourceSession session;

  /// 当前章放在第一项，优先开始加载；其余是现有调度器安排的相邻章。
  final List<OriginalChapter> chapters;
  final int current;
  final ValueListenable<double> slide;
  final OriginalPreloadGate preload;

  /// 长章实际布局足够重，按需离屏准备没有整体收益；直接沿用正常创建。
  /// 已经存在的启动实例仍正常接手，不因本次开书的章长丢弃它。
  final bool prepareOnDemand;
  @override
  State<OriginalBody> createState() => _OriginalBodyState();
}

class _ChapterFrame {
  _ChapterFrame(this.slot, this.load, this.chapter);
  final int slot;
  final int load;
  OriginalChapter chapter;
  late final OriginalHostController host;
  bool started = false;
  double? readyWidth;
  Object? preparedRevision;
  bool prepared = false;
  bool paginated = false;
  bool preparationFailed = false;
  Object? updateKey;
  Future<void> updateFlight = Future.value();
  String? styleKey;
  String? informationKey;
  Size? viewport;
  bool? backgroundAllowed;
}

class _OriginalBodyState extends State<OriginalBody> {
  final _captureBoundary = GlobalKey();
  late final _pageCapture = OriginalPageCapture(_captureBoundary);
  InAppWebViewController? _controller;
  OriginalHostController? _physicalHost;
  final _frames = <_ChapterFrame>[];
  int _load = 0;
  bool _shellReady = false;
  double _width = 0, _height = 0;
  Future<void> _syncFlight = Future.value();
  Future<void> _captureFlight = Future.value();
  String? _layoutKey;
  String? _pendingLayout;
  double? _pendingSlide;
  bool _syncing = false;
  _ChapterFrame? _heldFrame;
  bool _startupPrepared = OriginalWebViewWarmup.isPrepared;
  HeadlessInAppWebView? _preparedView = OriginalWebViewWarmup.takeFirstView();

  @override
  void initState() {
    super.initState();
    widget.preload.addListener(_preloadChanged);
    widget.slide.addListener(_moveSlide);
    if (_preparedView == null &&
        widget.prepareOnDemand &&
        OriginalWebViewWarmup.canPrepareFirstView &&
        ReaderDeliveryExperiments.originalRepeatView) {
      // 退出后重开及首次导入入口也准备首帧；在本次加载层下面完成，
      // 取得同一个实例后才建平台视图，避免准备一个却又创建另一个。
      _startupPrepared = false;
      unawaited(_prepareFirstView());
    } else if (!_startupPrepared) {
      OriginalWebViewWarmup.ensureReady().then((_) {
        if (mounted) setState(() => _startupPrepared = true);
      });
    }
  }

  Future<void> _prepareFirstView() async {
    await OriginalWebViewWarmup.prepareFirstView(originalWebViewSettings());
    final view = OriginalWebViewWarmup.takeFirstView();
    if (!mounted) {
      await view?.dispose();
      return;
    }
    setState(() {
      _preparedView = view;
      _startupPrepared = true;
    });
  }

  @override
  void dispose() {
    if (_preparedView?.isRunning() ?? false) {
      unawaited(_preparedView!.dispose());
    }
    widget.preload.removeListener(_preloadChanged);
    widget.slide.removeListener(_moveSlide);
    super.dispose();
  }

  void _resumePreparations() {
    if (!mounted) return;
    for (final frame in _frames) {
      if (frame.readyWidth == null ||
          frame.started ||
          !widget.preload.allows(frame.chapter.ordinal, widget.current)) {
        continue;
      }
      frame.started = true;
      unawaited(_start(frame, frame.readyWidth!));
    }
  }

  void _preloadChanged() {
    if (!mounted || !_shellReady) return;
    widget.session.allowPreparationBackground(!widget.preload.blocked);
    _syncChapters();
  }

  bool _alive(_ChapterFrame frame) => mounted && _frames.contains(frame);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!_startupPrepared) return const SizedBox.expand();
      final changed =
          _width != constraints.maxWidth || _height != constraints.maxHeight;
      final hadSize = _width > 0;
      _width = constraints.maxWidth;
      _height = constraints.maxHeight;
      if (changed && hadSize) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          for (final frame in _frames.where((f) => f.started)) {
            unawaited(_updateFrame(frame));
          }
        });
      }
      // 只截正文：翻页图、跳转遮盖与手柄都是父层 Stack 中的兄弟节点。
      return RepaintBoundary(
        key: _captureBoundary,
        child: InAppWebView(
          headlessWebView: _preparedView,
          initialUrlRequest: URLRequest(
            url: WebUri(
              'https://$kEpubSourceHost${kFrameworkPathPrefix}paged_host.html',
            ),
          ),
          initialSettings: originalWebViewSettings(),
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          onWebViewCreated: (controller) {
            _controller = controller;
            _physicalHost = OriginalHostController.fromWebView(
              controller,
              paginated: true,
            );
            controller.addJavaScriptHandler(
              handlerName: 'gtHost',
              callback: _onHostMessage,
            );
            traceTurn('pager created web=${controller.getViewId()}');
            if (_preparedView != null) {
              unawaited(_attachPreparedShell(controller));
            }
            if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
              unawaited(
                InAppWebViewController.setWebContentsDebuggingEnabled(true),
              );
            }
          },
          shouldInterceptRequest: _intercept,
          onConsoleMessage: (_, message) {
            if (message.messageLevel == ConsoleMessageLevel.ERROR) {
              reportOriginalConsoleError(
                message.message,
                operation: '原书脚本执行失败',
              );
            }
            if (readerPerformanceEnabled &&
                message.message.startsWith('GT_READER_PERF ')) {
              debugPrint(message.message);
            }
          },
          shouldOverrideUrlLoading: (controller, action) async {
            // 初次 iframe 导航只允许当前登记的章节；书内链接仍由 host.tap 上报。
            final url = action.request.url;
            if (url?.host == kEpubSourceHost &&
                (url?.path == '${kFrameworkPathPrefix}paged_host.html' ||
                    url.toString() == OriginalWebViewWarmup.pagedShellUrl ||
                    _frames.any(
                      (frame) => _url(frame).toString() == url.toString(),
                    ))) {
              return NavigationActionPolicy.ALLOW;
            }
            if (url.toString() == 'about:blank') {
              return NavigationActionPolicy.ALLOW;
            }
            return NavigationActionPolicy.CANCEL;
          },
          onLoadStop: (controller, url) async {
            if (_shellReady || !mounted) return;
            final ready = await controller.evaluateJavascript(
              source: '!!window.__gtPager',
            );
            traceTurn('pager shellLoaded ready=$ready');
            if (ready != true || !mounted) {
              return;
            }
            _shellReady = true;
            _syncChapters();
          },
          onReceivedError: (controller, request, error) {
            traceTurn('pager loadError code=${error.type}');
            if (request.isForMainFrame == true) {
              AppErrors.report(
                StateError('${error.type}: ${error.description}'),
                StackTrace.current,
                operation: '原书页面加载失败',
              );
            }
            for (final frame in _frames.where(
              (f) => _url(f).toString() == request.url.toString(),
            )) {
              frame.chapter.onHostEvent?.call({
                'type': 'loadError',
                'url': '${request.url}',
                'message': error.description,
              });
            }
          },
          onRenderProcessGone: (_, detail) async {
            AppErrors.report(
              StateError('didCrash=${detail.didCrash}'),
              StackTrace.current,
              operation: '原书渲染进程退出',
            );
          },
        ),
      );
    },
  );

  Future<void> _attachPreparedShell(InAppWebViewController controller) async {
    final ready = ReaderDeliveryExperiments.originalPagedShell
        ? await controller.evaluateJavascript(source: '!!window.__gtPager')
        : false;
    if (!mounted || !identical(controller, _controller)) return;
    if (ready == true) {
      traceTurn('pager prepared-shell reused web=${controller.getViewId()}');
      _shellReady = true;
      await _syncChapters();
    } else {
      // 兼容没有准备成分页外壳的实例，滚动入口也仍保留自己的导航流程。
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(
            'https://$kEpubSourceHost${kFrameworkPathPrefix}paged_host.html',
          ),
        ),
      );
    }
  }

  @override
  void didUpdateWidget(OriginalBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slide != widget.slide) {
      oldWidget.slide.removeListener(_moveSlide);
      widget.slide.addListener(_moveSlide);
    }
    // LayoutBuilder 得到新尺寸后再更新，避免一次旋转先按旧尺寸排一遍。
    if (_shellReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncChapters();
      });
    }
  }

  Uri _url(_ChapterFrame frame) {
    final url = widget.session.chapterUrl(frame.chapter.ordinal);
    return url.replace(
      queryParameters: {
        ...url.queryParameters,
        'gtSlot': '${frame.slot}',
        'gtLoad': '${frame.load}',
        'gtChapter': '${frame.chapter.ordinal}',
      },
    );
  }

  Future<void> _syncChapters() async {
    widget.session.allowPreparationBackground(!widget.preload.blocked);
    final controller = _controller;
    if (ReaderDeliveryExperiments.originalNativeResources &&
        controller != null) {
      await widget.session.bindResources(
        controller.getViewId()!,
        injection: _frameworkHead(null),
      );
      if (!mounted || !identical(controller, _controller)) return;
    }
    final ordinals = widget.chapters.map((chapter) => chapter.ordinal).toSet();
    _frames.removeWhere((frame) => !ordinals.contains(frame.chapter.ordinal));
    final updates = <_ChapterFrame>[];
    for (final chapter in widget.chapters) {
      final matches = _frames.where(
        (frame) => frame.chapter.ordinal == chapter.ordinal,
      );
      if (matches.isNotEmpty) {
        final frame = matches.first;
        frame.chapter = chapter; // 更新当前/邻章回调，不能保留上一角色的闭包。
        if (frame.started) updates.add(frame);
      } else {
        // 必须挡在 iframe.src 发布之前，仅挡 start 仍会让无关文档先解析。
        if (ReaderDeliveryExperiments.originalPriority &&
            !widget.preload.allows(chapter.ordinal, widget.current)) {
          continue;
        }
        final slot = [
          0,
          1,
          2,
        ].firstWhere((slot) => !_frames.any((f) => f.slot == slot));
        final frame = _ChapterFrame(slot, ++_load, chapter);
        frame.host = OriginalHostController.forFrame(
          _controller,
          evaluate: (script) => _evaluate(frame, script),
          evaluateAsync: (script) => _evaluate(frame, script, async: true),
          rendered: () => _rendered(frame),
          presented: () => _presented(frame),
          turnPresented: () => _presented(frame, afterPageTurn: true),
          capture: () => _capture(frame),
          holdPage: (page) => _holdPage(frame, page),
          releasePage: (committed) => _releasePage(frame, committed),
          preparePage: (page) async {
            await _evaluate(
              frame,
              '__gt.prepareImagePage(${page ?? 'null'})',
              async: true,
            );
          },
        );
        _frames.add(frame);
        traceTurn(
          'pager mount chapter=${chapter.ordinal} slot=$slot load=${frame.load} web=${_controller?.getViewId()} host=${identityHashCode(frame.host)}',
        );
      }
      // 父层可能刚裁剪了 hosts 表，重新登记保留章节的同一控制器。
      final frame = _frames.firstWhere(
        (f) => f.chapter.ordinal == chapter.ordinal,
      );
      chapter.onControllerReady?.call(frame.host);
      final allowed = !widget.preload.blocked;
      if (frame.readyWidth != null && frame.backgroundAllowed != allowed) {
        frame.backgroundAllowed = allowed;
        unawaited(_evaluate(frame, '__gt.setBackgroundAllowed($allowed)'));
      }
    }
    final specs = [
      for (final frame in _frames)
        {
          'slot': frame.slot,
          'load': frame.load,
          'chapter': frame.chapter.ordinal,
          'url': _url(frame).toString(),
          if (ReaderDeliveryExperiments.originalFinalLayout)
            'initialLayout': _initialLayout(frame.chapter),
        },
    ];
    final script =
        '__gtPager.sync(${jsonEncode(specs)}, ${widget.current}, ${widget.slide.value})';
    if (_layoutKey != script) {
      _layoutKey = script;
      _pendingLayout = script;
      if (!_syncing) {
        _syncing = true;
        _syncFlight = _flushLayout();
      }
    }
    _resumePreparations();
    for (final frame in updates) {
      unawaited(_updateFrame(frame));
    }
  }

  /// 桥接忙时只保留最新位移，不逐帧积压过时的跨章平移动作。
  /// 位移不再重建阅读页、重新同步三章或重新检查字体和信息栏。
  void _moveSlide() {
    if (!_shellReady) return;
    _pendingSlide = widget.slide.value;
    if (!_syncing) {
      _syncing = true;
      _syncFlight = _flushLayout();
    }
  }

  Future<void> _flushLayout() async {
    try {
      while (mounted && (_pendingLayout != null || _pendingSlide != null)) {
        final String script;
        if (_pendingLayout != null) {
          script = _pendingLayout!;
          _pendingLayout = null;
        } else {
          script = '__gtPager.shift(${widget.current}, $_pendingSlide)';
          _pendingSlide = null;
        }
        await _controller?.evaluateJavascript(source: script);
      }
    } finally {
      _syncing = false;
    }
  }

  Future<dynamic> _evaluate(
    _ChapterFrame frame,
    String script, {
    bool async = false,
  }) async {
    await _syncFlight;
    if (!_alive(frame)) return null;
    final call =
        '__gtPager.run(${frame.slot}, ${frame.load}, ${jsonEncode(script)})';
    if (async) {
      final result = await _controller?.callAsyncJavaScript(
        functionBody: 'return await $call;',
      );
      return result?.value;
    }
    return _controller?.evaluateJavascript(source: call);
  }

  Future<void> _rendered(_ChapterFrame frame) async {
    await _syncFlight;
    if (!_alive(frame)) return;
    if (OpeningExperiments.visibleImageDecode &&
        frame.host.deferredImagePixels) {
      await frame.host.prepareImagePage();
    }
    await _controller?.callAsyncJavaScript(
      functionBody: 'await __gtPager.rendered(${frame.slot}, ${frame.load});',
    );
  }

  Future<void> _presented(
    _ChapterFrame frame, {
    bool afterPageTurn = false,
  }) async {
    // 角色更新及临时截图还原完成后，才允许上层撤掉旧页遮盖。
    await _captureFlight;
    if (identical(_heldFrame, frame)) return; // 目标已确认且一直保留在屏幕上。
    await _syncFlight;
    await frame.updateFlight;
    if (!_alive(frame)) return;
    if (afterPageTurn && frame.paginated && !frame.preparationFailed) {
      // 切页命令及200ms运动已结束；图片就绪后交给Android visual-state / OnDraw
      // 确认同一目标画面，不再先串行等待网页的两个rAF。Flutter交接帧仍保留。
      await frame.host.prepareImagePage();
      await _controller?.callAsyncJavaScript(
        functionBody:
            'await __gtPager.turnRendered(${frame.slot}, ${frame.load});',
      );
      traceTurn('presented stable-turn chapter=${frame.chapter.ordinal}');
    } else {
      await _rendered(frame);
    }
    if (_alive(frame)) await _physicalHost?.presented();
  }

  Future<void> _holdPage(_ChapterFrame frame, int page) async {
    await traceTurnStep('hold wait-capture', () => _captureFlight);
    await traceTurnStep('hold wait-style', () => frame.updateFlight);
    await traceTurnStep('hold wait-layout', () => _syncFlight);
    if (!_alive(frame)) throw StateError('目标章节已失效');
    await frame.host.prepareImagePage(page);
    final shown = await traceTurnStep(
      'hold preview-command',
      () => _controller!.evaluateJavascript(
        source: '__gtPager.previewCapture(${frame.slot}, ${frame.load}, $page)',
      ),
    );
    if (shown != true) throw StateError('目标章节已失效');
    _heldFrame = frame;
    // previewCapture 已同步更新 DOM。原生回调仍等 visual-state、OnDraw
    // 及下一帧；取图仍等 Flutter 消费纹理，不能直接拿旧图层。
    await traceTurnStep('hold native-presented', _physicalHost!.presented);
    if (!_alive(frame)) throw StateError('目标章节已失效');
    _heldFrame = frame;
    traceTurn(
      'turn page held chapter=${frame.chapter.ordinal} page=$page load=${frame.load}',
    );
  }

  Future<void> _releasePage(_ChapterFrame frame, bool committed) async {
    await _captureFlight;
    if (!mounted || !identical(_heldFrame, frame)) return;
    _heldFrame = null;
    await _syncFlight;
    await _controller?.evaluateJavascript(source: '__gtPager.restore()');
    // 成功交接后当前槽就是目标，恢复角色不改变像素；取消则等旧槽真实上屏。
    if (!committed || widget.current != frame.chapter.ordinal) {
      await _physicalHost?.rendered();
      await _physicalHost?.presented();
    }
    traceTurn(
      'turn page released chapter=${frame.chapter.ordinal} current=${widget.current}',
    );
  }

  Future<ui.Image> _capture(_ChapterFrame frame) {
    final result = _captureFlight.then((_) async {
      await _syncFlight;
      await frame.updateFlight;
      if (!_alive(frame)) throw StateError('章节已离开预载窗口');
      if (!identical(_heldFrame, frame)) {
        final shown = await _controller!.evaluateJavascript(
          source: '__gtPager.showCapture(${frame.slot}, ${frame.load})',
        );
        if (shown != true) throw StateError('章节加载已过期');
      }
      ui.Image? image;
      try {
        if (!identical(_heldFrame, frame)) {
          await _rendered(frame);
          await _physicalHost!.presented();
        }
        if (!mounted) throw StateError('阅读页已关闭');
        image = await _pageCapture.capture(
          pixelRatio: View.of(context).devicePixelRatio,
          label: 'chapter=${frame.chapter.ordinal} load=${frame.load}',
          software: _physicalHost!.capture,
        );
        if (!_alive(frame)) {
          image.dispose();
          image = null;
          throw StateError('取图期间章节已失效');
        }
        return image;
      } finally {
        if (mounted && !identical(_heldFrame, frame)) {
          await _controller?.evaluateJavascript(source: '__gtPager.restore()');
          await _physicalHost?.rendered();
          await _physicalHost?.presented();
        }
      }
    });
    // 一次截图失败不阻塞后续用户请求；错误仍由本次调用交给现有翻页处理。
    _captureFlight = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> _updateFrame(_ChapterFrame frame) {
    final c = frame.chapter;
    final key = (
      c.fontSizePx,
      c.columnMarginPx,
      c.indent,
      c.fontFamily,
      c.fontWeight,
      c.themeColors.toString(),
      c.lineHeight,
      c.paragraphGapEm,
      c.preparationRevision,
      _width,
      _height,
      c.information?['top'],
      c.information?['bottom'],
      c.information?['pageTurnEffect'],
      c.information?['paintInHost'],
    );
    final changed = key != frame.updateKey;
    if (!changed && jsonEncode(c.information) == frame.informationKey) {
      return frame.updateFlight;
    }
    frame.updateKey = key;
    final repaginate = changed && frame.paginated;
    if (repaginate) {
      traceTurn(
        'pager reflow start chapter=${c.ordinal} size=${_width}x$_height',
      );
      frame.chapter.onHostEvent?.call({'type': 'preparing'});
    }
    // 初次准备和设置更新共用顺序，不能绕过正在加载的字体／高亮。
    final result = frame.updateFlight.then((_) async {
      if (!_alive(frame)) return;
      frame.preparationFailed = false;
      final viewport = Size(_width, _height);
      if (frame.paginated && frame.viewport != viewport) {
        await _evaluate(
          frame,
          '__gt.resize(${_width.round()}, ${frame.chapter.columnMarginPx.round()})',
        );
      }
      frame.viewport = viewport;
      await traceTurnStep(
        'load host-style chapter=${frame.chapter.ordinal}',
        () => _applyStyle(frame),
      );
      final c = frame.chapter;
      if (!frame.prepared || frame.preparedRevision != c.preparationRevision) {
        await traceTurnStep(
          'load host-position chapter=${c.ordinal}',
          () async => c.prepare?.call(frame.host),
        );
        if (!_alive(frame)) return;
        frame.prepared = true;
        frame.preparedRevision = c.preparationRevision;
      }
      final information = jsonEncode(frame.chapter.information);
      if (information != frame.informationKey) {
        frame.informationKey = information;
        await _evaluate(frame, '__gt.information($information)');
      }
      if (repaginate && _alive(frame) && frame.updateKey == key) {
        if (frame.chapter.ordinal != widget.current) {
          await frame.host.goToFraction(
            frame.chapter.ordinal < widget.current ? 1 : 0,
          );
        }
        await _rendered(frame);
        if (frame.chapter.ordinal == widget.current) {
          await _physicalHost?.presented();
        }
        final state = jsonDecode(await frame.host.state() as String) as Map;
        if (!_alive(frame) || frame.updateKey != key) return;
        traceTurn(
          'pager reflow ready chapter=${frame.chapter.ordinal} pages=${state['pages']} width=${state['width']}',
        );
        // 设置重排不重新 start；用已完成的分页结果更新两侧就绪和截图版本。
        frame.chapter.onHostEvent?.call({
          'type': 'paginated',
          'pages': state['pages'],
          'knownPages': state['knownPages'],
          'indexComplete': state['indexComplete'],
          'width': state['width'],
          'page': state['page'],
          'bookmarkPages': state['bookmarkPages'],
        });
      }
    });
    frame.host.preparation = result;
    frame.updateFlight = result.catchError((Object error, StackTrace stack) {
      if (!_alive(frame)) return;
      frame.preparationFailed = true;
      frame.updateKey = null; // 下次更新允许重试，不让一次读取失败阻断后续操作。
      frame.chapter.onHostEvent?.call({
        'type': 'loadError',
        'message': '$error',
      });
      traceTurn(
        'chapter preparation failed chapter=${frame.chapter.ordinal} type=${error.runtimeType}',
      );
    });
    return frame.updateFlight;
  }

  Future<void> _start(_ChapterFrame frame, double width) async {
    if (frame.chapter.deferStartUntilCurrent &&
        frame.chapter.ordinal != widget.current) {
      frame.started = false;
      return;
    }
    if (ReaderDeliveryExperiments.originalStartup) frame.host.beginStartup();
    await _updateFrame(frame);
    if (!_alive(frame) || frame.preparationFailed) {
      frame.host.cancelStartup();
      frame.styleKey = frame.informationKey = null;
      frame.prepared = false;
      return;
    }
    final c = frame.chapter;
    if (ReaderDeliveryExperiments.originalPriority &&
        !widget.preload.allows(c.ordinal, widget.current)) {
      frame.started = false;
      return;
    }
    traceTurn(
      'pager start chapter=${c.ordinal} load=${frame.load} '
      'exact=${frame.host.initialDomPoint != null}',
    );
    await _evaluate(
      frame,
      frame.host.finishStartupScript(
        '__gt.start(${width.round()}, ${c.columnMarginPx.round()}, ${c.initialFraction ?? 0}, ${jsonEncode(frame.host.initialDomPoint)})',
      ),
    );
    final geometry = await _evaluate(
      frame,
      'JSON.stringify({mode:document.compatMode,width:innerWidth,height:innerHeight})',
    );
    traceTurn(
      'pager geometry chapter=${c.ordinal} load=${frame.load} $geometry',
    );
  }
}
