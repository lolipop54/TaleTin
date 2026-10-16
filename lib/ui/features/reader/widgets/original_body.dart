/// 原书分页：一个 WebView 承载三个固定的章节 iframe。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../platform/channels/reading_fonts.dart';
import '../../../../core/diagnostics/opening_experiments.dart';
import '../../../../data/services/epub_source_repository.dart';
import 'original_host_controller.dart';
import 'original_page_capture.dart';
import 'original_preload_gate.dart';
import 'turn_trace.dart';

part 'original_chapter.dart';
part 'original_body_resources.dart';

const String kFrameworkPathPrefix = '/__gt__/';

class OriginalBody extends StatefulWidget {
  const OriginalBody({
    super.key,
    required this.session,
    required this.chapters,
    required this.current,
    required this.slide,
    required this.preload,
  });
  final EpubSourceSession session;

  /// 当前章放在第一项，优先开始加载；其余是现有调度器安排的相邻章。
  final List<OriginalChapter> chapters;
  final int current;
  final ValueListenable<double> slide;
  final OriginalPreloadGate preload;
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

  @override
  void initState() {
    super.initState();
    widget.preload.addListener(_resumePreparations);
    widget.slide.addListener(_moveSlide);
  }

  @override
  void dispose() {
    widget.preload.removeListener(_resumePreparations);
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

  bool _alive(_ChapterFrame frame) => mounted && _frames.contains(frame);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
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
      return RepaintBoundary(key: _captureBoundary, child: InAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(
            'https://$kEpubSourceHost${kFrameworkPathPrefix}paged_host.html',
          ),
        ),
        initialSettings: InAppWebViewSettings(
          useHybridComposition: false,
          javaScriptEnabled: true,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: false,
          allowFileAccess: false,
          allowContentAccess: false,
          cacheEnabled: false,
          supportZoom: false,
          transparentBackground: true,
          verticalScrollBarEnabled: false,
          horizontalScrollBarEnabled: false,
        ),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        onWebViewCreated: (controller) {
          _controller = controller;
          _physicalHost = OriginalHostController.fromWebView(controller);
          controller.addJavaScriptHandler(
            handlerName: 'gtHost',
            callback: _onHostMessage,
          );
          traceTurn('pager created web=${controller.getViewId()}');
          if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
            unawaited(
              InAppWebViewController.setWebContentsDebuggingEnabled(true),
            );
          }
        },
        shouldInterceptRequest: _intercept,
        onConsoleMessage: (_, message) {
          if (readerPerformanceEnabled && message.message.startsWith('GT_READER_PERF ')) {
            debugPrint(message.message);
          }
        },
        shouldOverrideUrlLoading: (controller, action) async {
          // 初次 iframe 导航只允许当前登记的章节；书内链接仍由 host.tap 上报。
          final url = action.request.url;
          if (url?.host == kEpubSourceHost &&
              (url?.path == '${kFrameworkPathPrefix}paged_host.html' ||
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
      ));
    },
  );

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

  void _syncChapters() {
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
        final slot = [
          0,
          1,
          2,
        ].firstWhere((slot) => !_frames.any((f) => f.slot == slot));
        final frame = _ChapterFrame(slot, ++_load, chapter);
        frame.host = OriginalHostController.forFrame(
          _controller,
          evaluate: (script) => _evaluate(frame, script),
          rendered: () => _rendered(frame),
          presented: () => _presented(frame),
          capture: () => _capture(frame),
          holdPage: (page) => _holdPage(frame, page),
          releasePage: (committed) => _releasePage(frame, committed),
          preparePage: (page) async {
            await _evaluate(frame, '__gt.prepareImagePage(${page ?? 'null'})', async: true);
          },
        );
        _frames.add(frame);
        traceTurn(
          'pager mount chapter=${chapter.ordinal} slot=$slot load=${frame.load} web=${_controller?.getViewId()} host=${identityHashCode(frame.host)}',
        );
      }
      // 父层可能刚裁剪了 hosts 表，重新登记保留章节的同一控制器。
      chapter.onControllerReady?.call(
        _frames.firstWhere((f) => f.chapter.ordinal == chapter.ordinal).host,
      );
    }
    final specs = [
      for (final frame in _frames)
        {
          'slot': frame.slot,
          'load': frame.load,
          'chapter': frame.chapter.ordinal,
          'url': _url(frame).toString(),
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
    if (OpeningExperiments.visibleImageDecode && frame.host.deferredImagePixels) {
      await frame.host.prepareImagePage();
    }
    await _controller?.callAsyncJavaScript(
      functionBody: 'await __gtPager.rendered(${frame.slot}, ${frame.load});',
    );
  }

  Future<void> _presented(_ChapterFrame frame) async {
    // 角色更新及临时截图还原完成后，才允许上层撤掉旧页遮盖。
    await _captureFlight;
    if (identical(_heldFrame, frame)) return; // 目标已确认且一直保留在屏幕上。
    await _rendered(frame);
    if (_alive(frame)) await _physicalHost?.presented();
  }

  Future<void> _holdPage(_ChapterFrame frame, int page) async {
    await traceTurnStep('hold wait-capture', () => _captureFlight);
    await traceTurnStep('hold wait-style', () => frame.updateFlight);
    await traceTurnStep('hold wait-layout', () => _syncFlight);
    if (!_alive(frame)) throw StateError('目标章节已失效');
    await frame.host.prepareImagePage(page);
    final shown = await traceTurnStep('hold preview-command', () =>
      _controller!.evaluateJavascript(
        source: '__gtPager.previewCapture(${frame.slot}, ${frame.load}, $page)'));
    if (shown != true) throw StateError('目标章节已失效');
    _heldFrame = frame;
    // previewCapture 已同步更新 DOM。原生回调仍等 visual-state、OnDraw
    // 及下一帧；取图仍等 Flutter 消费纹理，不能直接拿旧图层。
    await traceTurnStep('hold native-presented', _physicalHost!.presented);
    if (!_alive(frame)) throw StateError('目标章节已失效');
    _heldFrame = frame;
    traceTurn('turn page held chapter=${frame.chapter.ordinal} page=$page load=${frame.load}');
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
    traceTurn('turn page released chapter=${frame.chapter.ordinal} current=${widget.current}');
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

  Future<void> _applyStyle(_ChapterFrame frame) async {
    final c = frame.chapter;
    final key =
        '${c.fontSizePx}|${c.columnMarginPx}|${c.indent}|${c.fontFamily}|'
        '${c.fontWeight}|${c.themeColors}|${c.lineHeight}|${c.paragraphGapEm}';
    if (frame.styleKey == key) return;
    frame.styleKey = key;
    if (c.fontFamily.isNotEmpty) {
      await _evaluate(
        frame,
        'window.__gt && __gt.prepareFont(${jsonEncode(c.fontFamily)}, ${jsonEncode(ReadingFonts.cssFor(c.fontFamily))})',
        async: true,
      );
      if (!_alive(frame) || frame.styleKey != key) return;
    }
    await frame.host.applyStyle(
      fontSizePx: c.fontSizePx,
      lineHeight: c.lineHeight,
      paragraphGapEm: c.paragraphGapEm,
      marginPx: c.columnMarginPx,
      indent: c.indent,
      fontFamily: c.fontFamily,
      fontWeight: c.fontWeight,
      colors: c.themeColors,
    );
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
      _width, _height, c.information?['top'], c.information?['bottom'],
      c.information?['pageTurnEffect'], c.information?['paintInHost'],
    );
    final changed = key != frame.updateKey;
    if (!changed && jsonEncode(c.information) == frame.informationKey) {
      return frame.updateFlight;
    }
    frame.updateKey = key;
    final repaginate = changed && frame.paginated;
    if (repaginate) {
      traceTurn('pager reflow start chapter=${c.ordinal} size=${_width}x$_height');
      frame.chapter.onHostEvent?.call({'type': 'preparing'});
    }
    // 初次准备和设置更新共用顺序，不能绕过正在加载的字体／高亮。
    final result = frame.updateFlight.then((_) async {
      if (!_alive(frame)) return;
      frame.preparationFailed = false;
      final viewport = Size(_width, _height);
      if (frame.paginated && frame.viewport != viewport) {
        await _evaluate(frame,
          '__gt.resize(${_width.round()}, ${frame.chapter.columnMarginPx.round()})');
      }
      frame.viewport = viewport;
      await traceTurnStep('load host-style chapter=${frame.chapter.ordinal}', () => _applyStyle(frame));
      final c = frame.chapter;
      if (!frame.prepared || frame.preparedRevision != c.preparationRevision) {
        await traceTurnStep('load host-position chapter=${c.ordinal}', () async => c.prepare?.call(frame.host));
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
          await frame.host.goToFraction(frame.chapter.ordinal < widget.current ? 1 : 0);
        }
        await _rendered(frame);
        if (frame.chapter.ordinal == widget.current) {
          await _physicalHost?.presented();
        }
        final state = jsonDecode(await frame.host.state() as String) as Map;
        if (!_alive(frame) || frame.updateKey != key) return;
        traceTurn('pager reflow ready chapter=${frame.chapter.ordinal} pages=${state['pages']} width=${state['width']}');
        // 设置重排不重新 start；用已完成的分页结果更新两侧就绪和截图版本。
        frame.chapter.onHostEvent?.call({
          'type': 'paginated',
          'pages': state['pages'],
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

  Object? _onHostMessage(List<dynamic> args) {
    if (args.isEmpty || args.first is! String) return null;
    final envelope = (jsonDecode(args.first as String) as Map)
        .cast<String, Object?>();
    final matches = _frames.where(
      (frame) =>
          frame.slot == envelope['slot'] &&
          frame.load == envelope['load'] &&
          frame.chapter.ordinal == envelope['chapter'],
    );
    if (!mounted || matches.isEmpty) return null;
    final frame = matches.first;
    final event = (envelope['event'] as Map).cast<String, Object?>();
    traceTurn(
      'body event chapter=${frame.chapter.ordinal} slot=${frame.slot} load=${frame.load} web=${_controller?.getViewId()} type=${event['type']} page=${event['page']} pages=${event['pages']} stage=${event['stage']} jsMs=${event['ms']} elapsedMs=${event['elapsedMs']}',
    );
    if (event['type'] == 'paginated') {
      frame.paginated = true;
      if (event['deferredImagePixels'] case final bool deferred) {
        frame.host.deferredImagePixels = deferred;
      }
    }
    if (event['type'] == 'ready' && !frame.started) {
      frame.readyWidth = (event['width'] as num?)?.toDouble() ?? _width;
      _resumePreparations();
    }
    frame.chapter.onHostEvent?.call(event);
    return null;
  }

  Future<void> _start(_ChapterFrame frame, double width) async {
    await _updateFrame(frame);
    if (!_alive(frame) || frame.preparationFailed) return;
    final c = frame.chapter;
    await _evaluate(
      frame,
      '__gt.start(${width.round()}, ${c.columnMarginPx.round()}, ${c.initialFraction ?? 0})',
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
