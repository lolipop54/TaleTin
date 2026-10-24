import 'dart:async';
import 'dart:convert';

import 'package:taletin/core/diagnostics/app_errors.dart';

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show MethodChannel, OptionalMethodChannel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../core/diagnostics/opening_experiments.dart';
import '../../../../core/diagnostics/reader_delivery_experiments.dart';
import '../../../../core/diagnostics/reader_turn_diagnostics.dart';
import '../../../../core/diagnostics/reader_recovery_diagnostics.dart';
import 'turn_trace.dart';
import 'original_tap_target.dart';
export 'original_tap_target.dart';

part 'original_host_startup.dart';
part 'original_selection_geometry.dart';
part 'original_drag_delivery.dart';

/// 原书模式的诊断日志：只在 debug 构建输出。
///
/// 这些日志供性能验收和真机排查使用，不能进入 release 包。
void gtDebugLog(String message) {
  if (kDebugMode || const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
    debugPrint(message);
  }
}

/// 向原书宿主页下发命令、查询页序，并串行处理拖动位置。
class OriginalHostController {
  OriginalHostController.fromWebView(this._webView, {bool paginated = false})
    : _pagedTexturePending = paginated;

  // 仅物理分页宿主启用一次；iframe 控制器和连续滚动不从此处切换调度。
  bool _pagedTexturePending = false;

  /// 每次章节加载创建独立控制器，截图缓存继续按控制器身份区分文档。
  OriginalHostController.forFrame(
    this._webView, {
    required Future<dynamic> Function(String) evaluate,
    Future<dynamic> Function(String)? evaluateAsync,
    required Future<void> Function() rendered,
    required Future<void> Function() presented,
    Future<void> Function()? turnPresented,
    required Future<ui.Image> Function() capture,
    required Future<void> Function(int) holdPage,
    required Future<void> Function(bool) releasePage,
    Future<void> Function(int?)? preparePage,
  }) : _frameEvaluate = evaluate,
       _frameEvaluateAsync = evaluateAsync,
       _frameRendered = rendered,
       _framePresented = presented,
       _frameTurnPresented = turnPresented,
       _frameCapture = capture,
       _frameHoldPage = holdPage,
       _frameReleasePage = releasePage,
       _framePreparePage = preparePage;

  Future<dynamic> Function(String)? _frameEvaluate;
  Future<dynamic> Function(String)? _frameEvaluateAsync;
  Future<void> Function()? _frameRendered;
  Future<void> Function()? _framePresented;
  Future<void> Function()? _frameTurnPresented;
  Future<ui.Image> Function()? _frameCapture;
  Future<void> Function(int)? _frameHoldPage;
  Future<void> Function(bool)? _frameReleasePage;
  Future<void> Function(int?)? _framePreparePage;

  /// 宿主页根据已加载图片的像素量决定；小图片章节保持原来的完整解码。
  bool deferredImagePixels = false;

  /// 只等待目标页图片解码；不改图片尺寸和分页结果。
  Future<void> prepareImagePage([int? page]) async {
    if (OpeningExperiments.visibleImageDecode && deferredImagePixels) {
      await _framePreparePage?.call(page);
    }
  }

  int? _heldPage;
  Map<String, int> bookmarkPages = {};
  Future<Map<String, dynamic>?> currentBookmarkPoint() async {
    final value = await _evaluate(
      source: 'JSON.stringify(__gtInformation.currentPoint())',
    );
    return value is String
        ? (jsonDecode(value) as Map?)?.cast<String, dynamic>()
        : null;
  }

  Future<void> setBookmarks(List<Map<String, Object?>> points) async {
    if (_startupCommands != null) {
      _startupCommands!.add(
        '__gtInformation.setBookmarks(${jsonEncode(points)})',
      );
      return; // 正确页码随首次 paginated 返回，不查询尚未分栏的 DOM。
    }
    final value = await _evaluate(
      source:
          '__gtInformation.setBookmarks(${jsonEncode(points)}); JSON.stringify(__gtInformation.bookmarkPages())',
    );
    if (value is String) {
      bookmarkPages = (jsonDecode(value) as Map).map(
        (id, page) => MapEntry(id as String, (page as num).toInt()),
      );
    }
  }

  /// 目标页已完成绘制，并由本次翻页持有；提交无需再切回旧页。
  bool get hasHeldPage => _heldPage != null;

  Future<void> holdPage(int page) async {
    if (_heldPage == page) return;
    if (_frameHoldPage != null) {
      await _frameHoldPage!(page);
    } else {
      await previewPage(page);
    }
    _heldPage = page;
  }

  Future<void> releaseHeldPage({bool committed = false}) async {
    _heldPage = null;
    if (_frameReleasePage != null) {
      await _frameReleasePage!(committed);
    } else {
      await presented();
    }
  }

  Future<dynamic> _evaluate({required String source}) async =>
      _frameEvaluate != null
      ? _frameEvaluate!(source)
      : _webView?.evaluateJavascript(source: source);

  Future<dynamic> _evaluateAsync(String expression) async {
    if (!ReaderDeliveryExperiments.originalWindow || pageCount != null) {
      return _evaluate(source: expression);
    }
    if (_frameEvaluateAsync != null) return _frameEvaluateAsync!(expression);
    if (_frameEvaluate != null) return _frameEvaluate!(expression);
    return (await _webView?.callAsyncJavaScript(
      functionBody: 'return await ($expression);',
    ))?.value;
  }

  @visibleForTesting
  OriginalHostController.forTesting({
    Future<void> Function(String)? command,
    Future<bool> Function(String)? checkCommand,
  }) : _webView = null,
       _testCommand = command,
       _testCheckCommand = checkCommand;

  final InAppWebViewController? _webView;
  Future<void> Function(String)? _testCommand;
  Future<bool> Function(String)? _testCheckCommand;
  double? _pendingDrag;
  Future<void>? _dragFlight;
  Completer<void>? _dragIdle;
  int? _dragFrameCallback;
  Duration? _lastDragFrame;
  bool _dragEnding = false;
  ReaderTurnTrace? _turnDiagnosticTrace;
  int _dragInputs = 0, _dragCalls = 0, _dragTotalUs = 0, _dragMaxUs = 0;

  /// 就绪属于文档本身，不属于左/右预载槽；搬槽时不能丢失。
  int? pageCount;
  int knownPageCount = 0;
  bool get hasReadableWindow => pageCount != null || knownPageCount > 0;

  /// 首次 start 前准备的精确正文点；不消耗会话中的落页确认目标。
  Map<String, Object?>? initialDomPoint;
  List<String>? _startupCommands;
  bool contentMapReady = false;
  Future<void> setContentTitles(List<Map<String, Object>> titles) =>
      _call('__gt.setContentTitles(${jsonEncode(titles)})');
  Future<void> setContentMap(Map<String, Object> value) async {
    await _call('__gt.setContentMap(${jsonEncode(value)})');
    contentMapReady = true;
  }

  /// 当前设置、字体与标注的在途准备；只由章节容器更新。
  Future<void> preparation = Future.value();
  static bool _comparedCapture = false;

  /// 由阅读页管理工作区，换章或切换翻页方式时继续复用，退出时立即释放。
  static Future<void> setCaptureEnabled(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    const channel = OptionalMethodChannel('gtreader/page_capture');
    await channel.invokeMethod<void>('setEnabled', enabled);
  }

  Future<int?> adjacentPage(int delta) async =>
      (await _evaluateAsync('__gt.adjacentPage($delta)') as num?)?.toInt();

  Future<int> get page async {
    final value = jsonDecode((await state())!);
    return (value['page'] as num).toInt();
  }

  Future<double> fractionForPage(int page) async {
    if (contentMapReady) {
      final content = await _evaluate(
        source: '__gt.pageContentFraction($page)',
      );
      if (content is num) return content.toDouble();
    }
    // 页数由本次排版就绪事件维护，重排时会清空。顺序翻页的信息行无需再查一次网页。
    // 空白栏没有正文坐标，只有完整页数才能安全地走旧比例兼容。
    // 不能把 knownPageCount 的下界用作最终分母。
    if (pageCount == null) await _evaluateAsync('__gt.completeIndex()');
    final count =
        pageCount ?? (jsonDecode((await state())!)['pages'] as num).toInt();
    return page / count;
  }

  Future<void> previewPage(int page) async {
    await prepareImagePage(page);
    await _call('__gt.previewPage($page)');
    await rendered();
  }

  Future<void> commitPage(int page) async {
    await _call('__gt.commitPage($page)');
    if (_heldPage != page) await rendered();
  }

  /// 等待浏览器完成样式和合成，再通过 WebView 原生接口取得整页图像。
  Future<void> rendered() async {
    if (_frameRendered != null) return _frameRendered!();
    await traceTurnStep(
      'web=${_webView?.getViewId()} rendered',
      () =>
          _webView?.callAsyncJavaScript(
            functionBody: 'await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));',
          ) ??
          Future.value(),
    );
  }

  /// 跨文档复用时还要等待 Android 平台视图提交目标画面，不能只等网页帧。
  Future<void> presented() async {
    if (_framePresented != null) return _framePresented!();
    gtDebugLog('[gt] 平台绘制等待 ${_webView?.getViewId()}');
    if (_webView == null || defaultTargetPlatform != TargetPlatform.android) {
      return rendered();
    }
    const channel = MethodChannel('gtreader/page_capture');
    await traceTurnStep(
      'web=${_webView.getViewId()} presented',
      () => channel.invokeMethod<void>('presented', {
        'viewId': _webView.getViewId(),
        'trace': turnTraceEnabled,
        'traceInput': turnFrameTraceEnabled,
      }),
    );
    gtDebugLog('[gt] 平台绘制完成 ${_webView.getViewId()}');
    if (_pagedTexturePending) {
      _pagedTexturePending = false;
      // 首次完整窗口绘制之后再开启。后续 presented 仍执行上面的原生
      // visual-state / OnDraw 确认，不能用离屏回调替代目标页交接。
      await const OptionalMethodChannel('gtreader/original_scroll_draw')
          .invokeMethod<bool>('enablePaged', {'viewId': _webView.getViewId()});
    }
  }

  /// 已结束的普通翻页可以合并网页帧等待；开书、重排和截图仍走原确认。
  Future<void> pageTurnPresented() =>
      _frameTurnPresented?.call() ?? presented();

  Future<ui.Image> capture() async {
    if (_frameCapture != null) return _frameCapture!();
    const trace = bool.fromEnvironment('GT_PROFILE_CAPTURE');
    final watch = Stopwatch()..start();
    if (trace && !_comparedCapture) {
      _comparedCapture = true;
      await rendered();
      final bytes = (await _webView!.takeScreenshot())!;
      final codec = await ui.instantiateImageCodec(bytes);
      (await codec.getNextFrame()).image.dispose();
      codec.dispose();
      debugPrint('CURL_CAPTURE legacy=${watch.elapsedMilliseconds}ms');
      watch.reset();
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      const channel = MethodChannel('gtreader/page_capture');
      final data = (await traceTurnStep(
        'web=${_webView?.getViewId()} capture-channel',
        () => channel.invokeMapMethod<String, Object>('capture', {
          'viewId': _webView!.getViewId(),
          'trace': turnTraceEnabled,
          'traceInput': turnFrameTraceEnabled,
        }),
      ))!;
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        data['pixels'] as Uint8List,
      );
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: data['width'] as int,
        height: data['height'] as int,
        rowBytes: data['rowBytes'] as int,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      try {
        final codec = await descriptor.instantiateCodec();
        try {
          final image = (await codec.getNextFrame()).image;
          traceTurn(
            'capture decoded web=${_webView?.getViewId()} totalUs=${watch.elapsedMicroseconds} size=${image.width}x${image.height}',
          );
          if (trace) {
            debugPrint('CURL_CAPTURE raw=${watch.elapsedMilliseconds}ms');
          }
          return image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
        buffer.dispose();
      }
    }
    await rendered();
    final bytes = await _webView?.takeScreenshot();
    if (bytes == null) throw StateError('原书页面图像尚未就绪');
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  /// 切页后的绘制就绪由截图接口保证，不重复等待浏览器帧。
  Future<ui.Image> capturePage(int page) async {
    await prepareImagePage(page);
    await _call('__gt.previewPage($page)');
    return capture();
  }

  Future<OriginalTapTarget> tapTarget(Offset point) async {
    final value = await traceTurnStep(
      'tap web-hit-test',
      () => _evaluate(source: '__gt.tapTarget(${point.dx}, ${point.dy})'),
    );
    return OriginalTapTarget(
      jsonDecode(value as String) as Map<String, dynamic>,
    );
  }

  Future<bool> activateLink(Offset point, {String? knownLink}) async {
    final value =
        knownLink ??
        await _evaluate(source: '__gt.linkAt(${point.dx}, ${point.dy})');
    if (value is! String || value.isEmpty) return false;
    await _call('__gt.openLink(${jsonEncode(value)})');
    return true;
  }

  Future<String?> imageAt(Offset point) async =>
      await _evaluate(source: '__gt.imageAt(${point.dx}, ${point.dy})')
          as String?;

  /// 视口坐标的一点 → DOM 文本点（`{path, offset, width}`）；这一点没有文字时返回 null。
  ///
  /// 坐标是**宿主页视口的 CSS 像素**（手势坐标要先减掉阅读页里 WebView 的原点）；
  /// 返回的 width 是宿主页的视口宽，调用方按它换算矩形与手势坐标。
  Future<Map<String, Object?>?> selectionPointAt(
    Offset point, {
    bool character = false,
  }) async {
    final value = await _evaluate(
      source:
          'window.__gt ? __gt.selectionPointAt(${point.dx}, ${point.dy}, $character) : ""',
    );
    if (value is! String || value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  /// 扫描提交使用实际可见页首；纯图片页返回图片元素，文字页返回文字点。
  Future<Map<String, Object?>?> scanPageAnchor() async {
    final value = await _evaluate(source: '__gt.scanPageAnchor()');
    if (value is! String || value.isEmpty) return null;
    return (jsonDecode(value) as Map).cast<String, Object?>();
  }

  /// 本页靠近页首（[atEnd] 为 false）或页末（true）的文字位置；取不到时返回 null。
  Future<Map<String, Object?>?> selectionPageEdge({required bool atEnd}) async {
    final value = await _evaluate(
      source: 'window.__gt ? __gt.selectionPageEdge($atEnd) : ""',
    );
    if (value is! String || value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  /// 两个 DOM 文本点之间的矩形（视口坐标）与正文区范围。
  ///
  /// rects 为空表示这段范围在排版里没有可见矩形（例如端点已被替换）；
  /// 范围端点不合法时返回 null。
  Future<OriginalSelectionGeometry?> selectionRects(
    Map<String, Object?> from,
    Map<String, Object?> to, {
    String? color,
    String? handleColor,
    bool reversed = false,
  }) async {
    final value = await _evaluate(
      source:
          'window.__gt ? __gt.selectionRects(${jsonEncode(from)}, '
          '${jsonEncode(to)}, ${jsonEncode(color)}, ${jsonEncode(handleColor)}, $reversed) : ""',
    );
    if (value is! String || value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final list = decoded['rects'];
      if (list is! List) return null;
      final contentTop = (decoded['contentTop'] as num?)?.toDouble() ?? 0;
      final contentHeight = (decoded['contentHeight'] as num?)?.toDouble() ?? 0;
      final continuation = decoded['continuation'];
      final previous = decoded['previousContinuation'];
      Offset? anchor(String name) {
        final value = decoded[name];
        return value is Map
            ? Offset(
                (value['left'] as num).toDouble(),
                (value['bottom'] as num).toDouble(),
              )
            : null;
      }

      return OriginalSelectionGeometry(
        leading: anchor('leading'),
        trailing: anchor('trailing'),
        leadingHeight:
            ((decoded['leading'] as Map?)?['height'] as num?)?.toDouble() ?? 0,
        trailingHeight:
            ((decoded['trailing'] as Map?)?['height'] as num?)?.toDouble() ?? 0,
        continuationHeight: continuation is Map
            ? ((continuation['bottom'] as num) - (continuation['top'] as num))
                  .toDouble()
            : 0,
        previousContinuationHeight: previous is Map
            ? ((previous['bottom'] as num) - (previous['top'] as num))
                  .toDouble()
            : 0,
        previousContinuation: previous is Map
            ? Offset(
                (previous['left'] as num).toDouble(),
                (previous['bottom'] as num).toDouble(),
              )
            : null,
        continuation: continuation is Map
            ? Offset(
                (continuation['left'] as num).toDouble(),
                (continuation['bottom'] as num).toDouble(),
              )
            : null,
        width: (decoded['width'] as num?)?.toDouble() ?? 0,
        content: Rect.fromLTWH(0, contentTop, 0, contentHeight),
        textTop: (decoded['textTop'] as num?)?.toDouble() ?? 0,
        textBottom: (decoded['textBottom'] as num?)?.toDouble() ?? 0,
        pageFrom: decoded['pageFrom'] is Map
            ? (decoded['pageFrom'] as Map).cast<String, Object?>()
            : null,
        pageTo: decoded['pageTo'] is Map
            ? (decoded['pageTo'] as Map).cast<String, Object?>()
            : null,
        rects: [
          for (final item in list)
            if (item is Map)
              (
                page: (item['page'] as num?)?.toInt() ?? 0,
                onPage: item['onPage'] == true,
                rect: Rect.fromLTRB(
                  (item['left'] as num?)?.toDouble() ?? 0,
                  (item['top'] as num?)?.toDouble() ?? 0,
                  (item['right'] as num?)?.toDouble() ?? 0,
                  (item['bottom'] as num?)?.toDouble() ?? 0,
                ),
              ),
        ],
      );
    } on FormatException {
      return null;
    }
  }

  /// 临时选区只撤掉底色，已保存的高亮继续保留。
  Future<void> selectionHandleDrag(bool? atEnd) =>
      _call('__gt.selectionHandleDrag(${jsonEncode(atEnd)})');

  Future<void> clearSelection() => _call('__gt.clearSelection()');

  /// 下发这一章的持久高亮（笔记与高亮记录）：宿主页按内容坐标画在正文之上。
  ///
  /// [version] 只增不减：版本旧的下发会被宿主页丢掉（换章瞬间可能还有在飞的那一批）。
  Future<bool> setHighlights(
    List<Map<String, Object?>> items,
    int version,
  ) => _callCheck(
    '__gt.setHighlights(${jsonEncode({'version': version, 'items': items})})',
  );

  /// 清掉高亮（这一章没有可画的了）。
  Future<void> clearHighlights(int version) =>
      _call('__gt.clearHighlights($version)');

  /// 这一点压在哪条高亮上？返回那条记录的 id（没有就返回 null）。
  Future<String?> highlightAt(Offset point) async {
    final value = await _evaluate(
      source: 'window.__gt ? __gt.highlightAt(${point.dx}, ${point.dy}) : ""',
    );
    return value is String && value.isNotEmpty ? value : null;
  }

  /// 只返回当前页实际画出的想法尾缀，用同一份坐标绘制与命中。
  Future<List<({String id, Rect rect})>> thoughtMarkers() async {
    final value = await _evaluate(
      source: 'window.__gt ? __gt.thoughtMarkers() : "[]"',
    );
    final rows = jsonDecode(value as String? ?? '[]') as List;
    return [
      for (final row in rows)
        (
          id: row['id'] as String,
          rect: Rect.fromLTWH(
            (row['left'] as num).toDouble(),
            (row['top'] as num).toDouble(),
            (row['width'] as num).toDouble(),
            (row['height'] as num).toDouble(),
          ),
        ),
    ];
  }

  /// 下一页；到章末时宿主页会上报 `boundary`，由上层决定换章。
  Future<void> next() => _call('__gt.next()');

  /// 上一页。
  Future<void> prev() => _call('__gt.prev()');

  /// 按章内比例跳转（目录跳转、模式切换落点用）。
  Future<void> goToFraction(double fraction) =>
      _call('__gt.goToFraction($fraction)');

  Future<bool> goToDomPoint(Map<String, Object> point) =>
      _callCheck('__gt.goToDomPoint(${jsonEncode(point)})');

  Future<bool> followTtsPoint(Map<String, Object> point) =>
      _callCheck('__gt.followTtsPoint(${jsonEncode(point)})');

  Future<bool> setTtsRange(Map<String, Object> value) =>
      _callCheck('__gt.setTtsRange(${jsonEncode(value)})');

  Future<void> clearTtsRange(int version) =>
      _call('__gt.clearTtsRange($version)');

  Future<List<Map<String, dynamic>>?> ttsBoundaries(
    List<Map<String, Object>> nodes,
  ) async {
    final value = await _evaluate(
      source: 'JSON.stringify(__gt.ttsBoundaries(${jsonEncode(nodes)}))',
    );
    // 单双页切换会换掉 iframe；旧文档的查询按约定返回 null。
    // 与合法的空边界列表分开，调用方不能把取消查询当作已准备完成。
    if (value == null) return null;
    return (jsonDecode(value as String) as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// 按标题跳（目录条目名）。返回 false 表示正文里没有这个标题，
  /// 调用方改用锚点或章内比例。
  Future<bool> goToHeading(String title) async =>
      await _callCheck('__gt.goToHeading(${jsonEncode(title)})');

  /// 按 EPUB 目录链接定位：原始锚点优先，找不到才按标题或比例兜底。
  Future<void> goToTocTarget({
    String? anchorId,
    String? title,
    String? text,
    double? fraction,
  }) async {
    if (text != null &&
        text.isNotEmpty &&
        await _callCheck(
          '__gt.goToText(${jsonEncode(text)}, ${fraction ?? 0})',
        )) {
      return;
    }
    if (anchorId != null && anchorId.isNotEmpty) {
      final found = await _callCheck(
        '__gt.goToAnchor(${jsonEncode(anchorId)})',
      );
      if (found) return;
    }
    if (title != null && title.trim().isNotEmpty) {
      final found = await goToHeading(title.trim());
      if (found) return;
    }
    if (fraction != null) await goToFraction(fraction);
  }

  /// 与 [_call] 相同，但把宿主页的返回值带回来（落点需要“找到没有”）。
  Future<bool> _callCheck(String script) async {
    if (_testCheckCommand != null) return _testCheckCommand!(script);
    if (_testCommand != null) {
      await _testCommand!(script);
      return false;
    }
    try {
      // 包成有返回值的表达式；if 语句会返回 undefined，导致落点误判。
      final result = await _evaluateAsync(
        '(function () { if (window.__gt) { return $script; }'
        ' return false; })()',
      );
      return result == true || '$result' == 'true';
    } on Object catch (error, stack) {
      AppErrors.report(error, stack, operation: '原书定位指令失败');
      gtDebugLog('[gt] 下发失败：$script → $error');
      return false;
    }
  }

  /// 跳到文档内的锚点（书内链接的 `#片段`）。
  Future<void> goToAnchor(String id) =>
      _call('__gt.goToAnchor(${jsonEncode(id)})');

  /// 重排并保持位置（图片就绪、字号变化后）。
  Future<void> relayout() => _call('__gt.relayout(true)');

  /// 主题与字号的覆盖式更新。
  ///
  /// [fontSizePx] 是“用户字号 × 系统缩放”的像素值；[colors] 是阅读主题
  /// 的取色（bg / text / link）。原书样式表不动，只在其后追加一条覆盖规则。
  Future<void> applyStyle({
    double? fontSizePx,
    double? lineHeight,
    double? paragraphGapEm,
    double? marginPx,
    bool? indent,
    String? fontFamily,
    int? fontWeight,
    Map<String, String>? colors,
    Map<String, Object?>? initialInformation,
  }) => _call(
    '__gt.${initialInformation == null ? 'applyStyle' : 'configure'}(${jsonEncode({'fontSizePx': ?fontSizePx, 'lineHeight': ?lineHeight, 'paragraphGapEm': ?paragraphGapEm, 'marginPx': ?marginPx, 'indent': ?indent, 'fontFamily': ?fontFamily, 'fontWeight': ?fontWeight, 'colors': ?colors})}${initialInformation == null ? '' : ', ${jsonEncode(initialInformation)}'})',
  );

  /// 点击：分区由 Flutter 算好，一次调用里判断链接并执行相应动作。
  Future<void> tap(
    double x,
    double y,
    String zone, {
    int animationDurationMs = 200,
  }) => _call(
    '__gt.tap(${x.round()}, ${y.round()}, "$zone", $animationDurationMs)',
  );

  /// 真实边界：`end` 章末、`start` 章首、空串表示都不是。
  Future<String?> atEdge() async {
    try {
      final value = await _evaluate(source: "window.__gt ? __gt.atEdge() : ''");
      return value is String ? value : null;
    } on Object {
      return null;
    }
  }

  /// 宿主页状态（页数、当前页），调试用。
  Future<String?> state() async {
    try {
      final value = await _evaluate(
        source: 'window.__gt ? __gt.state() : null',
      );
      return value is String ? value : null;
    } on Object {
      return null;
    }
  }

  /// 自检：各项页数测量值并列返回，用来定位翻不到的页面。
  Future<String?> audit() async {
    try {
      final value = await _evaluate(
        source: 'window.__gt ? __gt.audit() : null',
      );
      return value is String ? value : null;
    } on Object {
      return null;
    }
  }

  Future<void> _call(String script) async {
    if (ReaderRecoveryDiagnostics.observing) {
      final command = script.split('(').first;
      if (const {
        '__gt.resize',
        '__gt.information',
        '__gt.applyStyle',
        '__gt.previewPage',
        '__gt.commitPage',
        '__gt.next',
        '__gt.prev',
        '__gt.relayout',
        '__gt.goToFraction',
        '__gt.settle',
      }.contains(command)) {
        ReaderRecoveryDiagnostics.record('hostCommand', {
          'command': command,
          'host': identityHashCode(this),
          'knownPages': knownPageCount,
          'pages': pageCount,
          'heldPage': _heldPage,
        });
      }
    }
    if (_queueStartup(script)) return;
    if (_testCommand != null) return _testCommand!(script);
    final diagnostic = _turnDiagnosticTrace;
    final sequence = diagnostic != null && diagnostic.endUs == null
        ? diagnostic.commandBegin(
            script.split('(').first,
            hostToken: identityHashCode(this),
          )
        : 0;
    try {
      final observed = sequence == 0
          ? script
          : '(window.gtReaderTurnDiagnostics ? '
                'window.gtReaderTurnDiagnostics.run(${jsonEncode(diagnostic!.id)},'
                // 分页动画由Flutter页图完成，不用诊断rAF驱动静止的底层网页。
                '$sequence,function(){return ($script);},false) : ($script))';
      // 换章瞬间命令可能打到还没跑起 host.js 的新文档上。
      await traceTurnStep(
        'web=${_webView?.getViewId()} command=${script.split('(').first}',
        () => _evaluateAsync(
          'window.__gt ? (${_diagnosticCommand(observed)}) : null',
        ),
      );
    } on Object catch (error, stack) {
      AppErrors.report(error, stack, operation: '原书页面指令失败');
      diagnostic?.event('command.error', [error.runtimeType.toString()]);
      traceTurn(
        'command ignored web=${_webView?.getViewId()} type=${error.runtimeType}',
      );
      // WebView 已销毁或脚本报错：翻页失败不应把界面带崩。
    } finally {
      if (sequence != 0) diagnostic!.commandEnd(sequence);
    }
  }

  // 诊断只量网页函数执行，不把平台往返或等待浏览器调度算成该函数CPU。
  String _diagnosticCommand(String script) {
    if (!turnTraceEnabled) return script;
    final command = jsonEncode(script.split('(').first);
    return '(function(){var start=performance.now();try{return ($script);}'
        'finally{window.__gtHost.post("turnTrace",{stage:"startup-command",'
        'command:$command,ms:performance.now(),elapsedMs:performance.now()-start});}})()';
  }
}
