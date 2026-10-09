import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, OptionalMethodChannel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'turn_trace.dart';
import 'original_tap_target.dart';
export 'original_tap_target.dart';

/// 原书模式的诊断日志：只在 debug 构建输出。
///
/// 这些日志供性能验收和真机排查使用，不能进入 release 包。
void gtDebugLog(String message) {
  if (kDebugMode || const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
    debugPrint(message);
  }
}

/// 原书选区几何：宿主页视口宽、正文区范围与选区矩形（都在宿主页视口坐标里）。
///
/// [content] 是正文区（不含上下信息行）在视口里的纵向范围：页首/页末判定、
/// 「手指推出正文区」都用它，免得把信息行当成正文的一部分。
class OriginalSelectionGeometry {
  const OriginalSelectionGeometry({
    required this.width,
    required this.content,
    required this.textTop,
    required this.textBottom,
    required this.rects,
    this.pageFrom,
    this.pageTo,
    this.continuation,
    this.previousContinuation,
  });

  /// 宿主页视口宽（CSS 像素）
  final double width;

  /// 正文区（不含上下信息行）的纵向范围；横向范围对多栏正文没有意义
  final Rect content;

  /// 本页第一行文字的上沿与最后一行文字的下沿（视口坐标）
  final double textTop;
  final double textBottom;

  /// 选区矩形（视口坐标）、它在排版的第几页（相对当前页，诊断用）
  /// 以及它是否落在当前页上（判定用，不看页序）
  final List<({int page, bool onPage, Rect rect})> rects;

  /// 本页那一段选区的首/末文字在 DOM 上的位置（把范围夹在本页内用它）
  final Map<String, Object?>? pageFrom;
  final Map<String, Object?>? pageTo;

  /// 页末终点在下一页首字旁的可拖动落点，不扩选正文。
  final Offset? continuation;

  /// 页首起点在上一页末字旁的可拖动落点，不扩选正文。
  final Offset? previousContinuation;

  /// 同章翻页只平移横坐标，先用已准备的几何接上新页，再由网页复核。
  OriginalSelectionGeometry shifted(int pages) {
    final delta = Offset(-pages * width, 0);
    return OriginalSelectionGeometry(
      width: width,
      content: content,
      textTop: textTop,
      textBottom: textBottom,
      continuation: continuation == null ? null : continuation! + delta,
      previousContinuation: previousContinuation == null
          ? null
          : previousContinuation! + delta,
      rects: [
        for (final item in rects)
          (
            page: item.page - pages,
            onPage:
                item.rect.right + delta.dx > 1 &&
                item.rect.left + delta.dx < width - 1,
            rect: item.rect.shift(delta),
          ),
      ],
    );
  }
}

/// 向原书宿主页下发命令、查询页序，并串行处理拖动位置。
class OriginalHostController {
  OriginalHostController.fromWebView(this._webView);

  /// 每次章节加载创建独立控制器，截图缓存继续按控制器身份区分文档。
  OriginalHostController.forFrame(this._webView, {
    required Future<dynamic> Function(String) evaluate,
    required Future<void> Function() rendered,
    required Future<void> Function() presented,
    required Future<ui.Image> Function() capture,
    required Future<void> Function(int) holdPage,
    required Future<void> Function(bool) releasePage,
  }) : _frameEvaluate = evaluate, _frameRendered = rendered,
       _framePresented = presented, _frameCapture = capture,
       _frameHoldPage = holdPage, _frameReleasePage = releasePage;

  Future<dynamic> Function(String)? _frameEvaluate;
  Future<void> Function()? _frameRendered;
  Future<void> Function()? _framePresented;
  Future<ui.Image> Function()? _frameCapture;
  Future<void> Function(int)? _frameHoldPage;
  Future<void> Function(bool)? _frameReleasePage;
  int? _heldPage;
  Map<String, int> bookmarkPages = {};
  Future<Map<String, dynamic>?> currentBookmarkPoint() async {
    final value = await _evaluate(source: 'JSON.stringify(__gtInformation.currentPoint())');
    return value is String ? (jsonDecode(value) as Map?)?.cast<String, dynamic>() : null;
  }
  Future<void> setBookmarks(List<Map<String, Object?>> points) async {
    final value = await _evaluate(source: '__gtInformation.setBookmarks(${jsonEncode(points)}); JSON.stringify(__gtInformation.bookmarkPages())');
    if (value is String) {
      bookmarkPages = (jsonDecode(value) as Map).map((id, page) => MapEntry(id as String, (page as num).toInt()));
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
      _frameEvaluate != null ? _frameEvaluate!(source) :
      _webView?.evaluateJavascript(source: source);

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
  int _dragInputs = 0, _dragCalls = 0, _dragTotalUs = 0, _dragMaxUs = 0;

  /// 就绪属于文档本身，不属于左/右预载槽；搬槽时不能丢失。
  int? pageCount;

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
      (await _evaluate(
        source: '__gt.adjacentPage($delta)',
      ) as num?)?.toInt();

  Future<int> get page async {
    final value = jsonDecode((await state())!);
    return (value['page'] as num).toInt();
  }

  Future<double> fractionForPage(int page) async {
    // 页数由本次排版就绪事件维护，重排时会清空。顺序翻页的信息行无需再查一次网页。
    final count = pageCount ?? (jsonDecode((await state())!)['pages'] as num).toInt();
    return page / count;
  }

  Future<void> previewPage(int page) async {
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
    await traceTurnStep('web=${_webView?.getViewId()} rendered', () => _webView?.callAsyncJavaScript(
      functionBody: 'await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));',
    ) ?? Future.value());
  }

  /// 跨文档复用时还要等待 Android 平台视图提交目标画面，不能只等网页帧。
  Future<void> presented() async {
    if (_framePresented != null) return _framePresented!();
    gtDebugLog('[gt] 平台绘制等待 ${_webView?.getViewId()}');
    if (_webView == null || defaultTargetPlatform != TargetPlatform.android) {
      return rendered();
    }
    const channel = MethodChannel('gtreader/page_capture');
    await traceTurnStep('web=${_webView.getViewId()} presented', () => channel.invokeMethod<void>('presented', {
      'viewId': _webView.getViewId(),
      'trace': turnTraceEnabled,
      'traceInput': turnFrameTraceEnabled,
    }));
    gtDebugLog('[gt] 平台绘制完成 ${_webView.getViewId()}');
  }

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
      final data = (await traceTurnStep('web=${_webView?.getViewId()} capture-channel', () => channel.invokeMapMethod<String, Object>('capture', {
        'viewId': _webView!.getViewId(),
        'trace': turnTraceEnabled,
        'traceInput': turnFrameTraceEnabled,
      })))!;
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
          traceTurn('capture decoded web=${_webView?.getViewId()} totalUs=${watch.elapsedMicroseconds} size=${image.width}x${image.height}');
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
    await _call('__gt.previewPage($page)');
    return capture();
  }

  Future<OriginalTapTarget> tapTarget(Offset point) async {
    final value = await traceTurnStep('tap web-hit-test', () => _evaluate(
      source: '__gt.tapTarget(${point.dx}, ${point.dy})'));
    return OriginalTapTarget(jsonDecode(value as String) as Map<String, dynamic>);
  }

  Future<bool> activateLink(Offset point, {String? knownLink}) async {
    final value = knownLink ?? await _evaluate(
      source: '__gt.linkAt(${point.dx}, ${point.dy})',
    );
    if (value is! String || value.isEmpty) return false;
    await _call('__gt.openLink(${jsonEncode(value)})');
    return true;
  }

  Future<String?> imageAt(Offset point) async =>
      await _evaluate(
        source: '__gt.imageAt(${point.dx}, ${point.dy})',
      ) as String?;

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
      return OriginalSelectionGeometry(
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
      source: 'window.__gt ? __gt.thoughtMarkers() : "[]"');
    final rows = jsonDecode(value as String? ?? '[]') as List;
    return [for (final row in rows) (id: row['id'] as String,
      rect: Rect.fromLTWH((row['left'] as num).toDouble(), (row['top'] as num).toDouble(),
        (row['width'] as num).toDouble(), (row['height'] as num).toDouble()))];
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

  Future<List<Map<String, dynamic>>> ttsBoundaries(
    List<Map<String, Object>> nodes,
  ) async {
    final value = await _evaluate(
      source: 'JSON.stringify(__gt.ttsBoundaries(${jsonEncode(nodes)}))',
    );
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
      final result = await _evaluate(
        source:
            '(function () { if (window.__gt) { return $script; }'
            ' return false; })()',
      );
      return result == true || '$result' == 'true';
    } on Object catch (error) {
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
    bool? bold,
    Map<String, String>? colors,
  }) => _call(
    '__gt.applyStyle(${jsonEncode({'fontSizePx': ?fontSizePx, 'lineHeight': ?lineHeight, 'paragraphGapEm': ?paragraphGapEm, 'marginPx': ?marginPx, 'indent': ?indent, 'fontFamily': ?fontFamily, 'bold': ?bold, 'colors': ?colors})})',
  );

  /// 点击：分区由 Flutter 算好，一次调用里判断链接并执行相应动作。
  Future<void> tap(double x, double y, String zone, {int animationDurationMs = 200}) =>
      _call('__gt.tap(${x.round()}, ${y.round()}, "$zone", $animationDurationMs)');

  /// 拖动中让页面跟手平移；桥忙时只保留最新位置。
  Future<void> drag(double dx) {
    if (readerPerformanceEnabled) _dragInputs++;
    _pendingDrag = dx;
    return _dragFlight ??= _drainDrag();
  }

  Future<void> _drainDrag() async {
    try {
      while (_pendingDrag != null) {
        final dx = _pendingDrag!;
        _pendingDrag = null;
        final watch = readerPerformanceEnabled ? (Stopwatch()..start()) : null;
        await _call('__gt.drag(${dx.round()})');
        if (watch != null) {
          final us = watch.elapsedMicroseconds;
          _dragCalls++;
          _dragTotalUs += us;
          if (us > _dragMaxUs) _dragMaxUs = us;
        }
      }
    } finally {
      _dragFlight = null;
    }
  }

  /// 执行手势层决定的页差（-1／0／1）；旧拖动不能覆盖补完动画。
  Future<void> settle(int pageDelta) async {
    _pendingDrag = null;
    await _dragFlight;
    if (readerPerformanceEnabled && _dragInputs > 0) {
      readerPerf('original.slide.dragBridge', _dragTotalUs,
          {'inputs': _dragInputs, 'calls': _dragCalls, 'maxUs': _dragMaxUs});
      _dragInputs = _dragCalls = _dragTotalUs = _dragMaxUs = 0;
    }
    await _call('__gt.settle($pageDelta)');
  }

  /// 真实边界：`end` 章末、`start` 章首、空串表示都不是。
  Future<String?> atEdge() async {
    try {
      final value = await _evaluate(
        source: "window.__gt ? __gt.atEdge() : ''",
      );
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
    if (_testCommand != null) return _testCommand!(script);
    try {
      // 换章瞬间命令可能打到还没跑起 host.js 的新文档上。
      await traceTurnStep('web=${_webView?.getViewId()} command=${script.split('(').first}', () => _evaluate(
        source: 'if (window.__gt) { $script; }',
      ));
    } on Object catch (error) {
      traceTurn('command ignored web=${_webView?.getViewId()} type=${error.runtimeType}');
      // WebView 已销毁或脚本报错：翻页失败不应把界面带崩。
    }
  }
}
