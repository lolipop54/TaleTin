import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'page_canvas.dart';
import '../view_models/reader_session_view_model.dart' show SpreadPageRef;
import 'spread_fold.dart';
import 'page_fold.dart';
import 'page_ink.dart';
import 'page_curl_texture.dart';
import 'prepared_page.dart';
import 'prepared_page_cache.dart';
import 'page_raster_cache.dart';
import 'book_paper.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';

/// 一次手势冻结两页，动画结束或取消后统一释放。
class FoldFrames {
  FoldFrames(PreparedPage current, PreparedPage target, [this._rasterCache])
    : footerTarget = null, _current = current,
      _target = target,
      bookEdges = current.page.information?.bookEdges ?? false,
      paper = current.page.theme.background,
      backgroundImage = current.backgroundImage;
  FoldFrames.spread(
    ui.Image current,
    ui.Image target,
    Size size, {
    required bool backward,
    required this.paper,
    this.backgroundImage,
    this.footerTarget,
    bool edges = false,
  }) : bookEdges = false,
       _current = null,
       _target = null,
       _rasterCache = null,
       spread = SpreadFold(current, target, size, backward, edges: edges);
  SpreadFold? spread;
  final SpreadPageRef? footerTarget;
  SpreadPageRef? get numberedTarget {
    final page = _target?.page;
    return page == null ? footerTarget : (layout: page.layout, pageIndex: page.pageIndex);
  }
  final PreparedPage? _current, _target;
  PreparedPage get current => _current!;
  PreparedPage get target => _target!;
  PreparedPage? get preparedCurrent => _current;
  PreparedPage? get preparedTarget => _target;
  final Color paper;
  final ui.Image? backgroundImage;
  final bool bookEdges;
  final PageRasterCache? _rasterCache;
  ui.Image? _underImage;
  PageCurlTexture? _curlTexture;
  bool get hasPageImages => _underImage != null;

  /// WebView 通过自身截图接口准备页面；图像随本次手势释放。
  FoldFrames.images(
    ui.Image current,
    ui.Image target,
    Size size, {
    required bool backward,
    required this.paper,
    this.backgroundImage,
    this.bookEdges = false,
    this.footerTarget,
  }) : _current = null,
       _target = null,
       _rasterCache = null {
    _turningImage = backward ? target : current;
    _underImage = backward ? current : target;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      _underImage!,
      Rect.fromLTWH(
        0,
        0,
        _underImage!.width.toDouble(),
        _underImage!.height.toDouble(),
      ),
      Offset.zero & size,
      _imagePaint,
    );
    _underPicture = recorder.endRecording();
  }
  ui.Image? _turningImage;
  ui.Image? _leafImage;
  ui.Image get turningImage => _leafImage ?? _turningImage!;
  Size leafSize(Size size) =>
      Size(size.width - (bookEdges ? bookEdgeWidth : 0), size.height);
  double coverLeft(Size size, double offset, bool backward) {
    final width = leafSize(size).width;
    final shift = offset * width / size.width;
    return (backward ? shift - width : shift).clamp(-width, 0.0);
  }

  ui.Picture? _underPicture;
  ui.Picture? _slideCurrent, _slideTarget;
  bool get hasPreparedSlide => _slideTarget != null;
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;

  /// 图文页平移时两页都要露出。在第一次拖动也只录一遍绘制指令，
  /// 空闲时已画成整页图则直接取图，不为手势另外等待一次光栅化。
  void prepareSlide(Size size, double ratio) {
    if (_rasterCache == null || hasPreparedSlide || paper.a != 1 ||
        (!current.hasBookImages && !target.hasBookImages)) {
      return;
    }
    ui.Picture record(PreparedPage page) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final image = _rasterCache.find(page, size, ratio);
      if (image == null) {
        page.paint(canvas, size);
      } else {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Offset.zero & size,
          _imagePaint,
        );
        image.dispose();
      }
      return recorder.endRecording();
    }
    _slideCurrent = record(current);
    _slideTarget = record(target);
  }

  /// 每次手势只生成一次；按屏幕像素密度缓存，卷曲时不重复绘制字形。
  /// toImageSync 返回 GPU 图像句柄，光栅化由引擎排队完成，不回读 CPU。
  void preparePainting(
    Size size,
    double pixelRatio, {
    bool backward = false,
    bool curl = true,
  }) {
    if (spread != null) return;
    if (_turningImage != null) {
      if (curl && _curlTexture == null) _prepareLeaf(size);
      return;
    }
    final width = (size.width * pixelRatio).ceil();
    final height = (size.height * pixelRatio).ceil();
    ui.Image rasterize(PreparedPage page) {
      final cached = _rasterCache?.find(page, size, pixelRatio);
      if (cached != null) return cached;
      final trace = ReaderWorkTrace.start('page.raster_image_sync', {
        'width': width,
        'height': height,
      });
      final recorder = ui.PictureRecorder();
      page.paint(Canvas(recorder)..scale(pixelRatio), size);
      final picture = recorder.endRecording();
      try {
        return picture.toImageSync(width, height);
      } finally {
        picture.dispose();
        trace?.finish();
      }
    }

    _turningImage = rasterize(backward ? target : current);
    final under = backward ? current : target;
    final underRecorder = ui.PictureRecorder();
    final underCanvas = Canvas(underRecorder);
    // Picture 只记录绘制指令。整页背景和插图会随每次拖动再次合成。
    // 在翻页手势内复用底页的原分辨率图。超出单张预算的纸面沿用指令绘制。
    final canUseTexture = curl && paper.a == 1;
    // 纯文字底页也可能已有整页图，只借已准备好的图，不在起手时额外生成。
    final readyUnder = canUseTexture && !under.hasBookImages
        ? _rasterCache?.find(under, size, pixelRatio)
        : null;
    if (readyUnder != null || (under.hasBookImages &&
        width * height * 4 <= PageRasterCache.maxPageBytes &&
        width * height * 4 <=
            (_rasterCache?.budgetBytes ?? PageRasterCache.defaultBudgetBytes))) {
      final image = _underImage = readyUnder ?? rasterize(under);
      underCanvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Offset.zero & size,
        _imagePaint,
      );
      if (canUseTexture) {
        _curlTexture = PageCurlTexture.create(
          _turningImage!, image, size, pixelRatio, paper,
        );
      }
    } else {
      under.paint(underCanvas, size);
    }
    _underPicture = underRecorder.endRecording();
    if (curl && _curlTexture == null) _prepareLeaf(size);
  }

  void _prepareLeaf(Size size) {
    if (!bookEdges || _leafImage != null) return;
    final source = _turningImage!;
    final width = (source.width * leafSize(size).width / size.width).round();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(source, Offset.zero, _imagePaint);
    final picture = recorder.endRecording();
    _leafImage = picture.toImageSync(width, source.height);
    picture.dispose();
  }

  void paintTurning(Canvas canvas, Size size) {
    final image = _turningImage!;
    canvas.save();
    canvas.clipRect(Offset.zero & leafSize(size));
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      _imagePaint,
    );
    canvas.restore();
  }

  void paintUnder(Canvas canvas) => canvas.drawPicture(_underPicture!);

  static Future<FoldFrames> load(
    PageCanvas current,
    PageCanvas target,
    ImageConfiguration configuration, {
    PageRasterCache? rasterCache,
    PreparedPageCache? materialCache,
  }) async {
    final pages = await Future.wait([
      Future<PreparedPage>.value(
        materialCache?.find(current, configuration) ??
            PreparedPage.load(current, configuration),
      ),
      Future<PreparedPage>.value(
        materialCache?.find(target, configuration) ??
            PreparedPage.load(target, configuration),
      ),
    ]);
    // 有书内底图时，文字的对比色取决于已准备好的背景。和最终绘制共用同一份文字缓存。
    for (final page in pages) {
      page.prepareText();
    }
    return FoldFrames(pages[0], pages[1], rasterCache);
  }

  void dispose() {
    _curlTexture?.dispose();
    _slideCurrent?.dispose();
    _slideTarget?.dispose();
    spread?.dispose();
    _leafImage?.dispose();
    _turningImage?.dispose();
    _underPicture?.dispose();
    _underImage?.dispose();
    _current?.dispose();
    _target?.dispose();
  }
}

/// 平移和覆盖可以直接移动完整组件，让缓存正文与独立刷新的页码共用纸张坐标。
class FlatFramePage extends CustomPainter {
  const FlatFramePage(
    this.frames, {
    required this.next,
    required this.backward,
    required this.cover,
  });
  final FoldFrames frames;
  final bool next, backward, cover;

  @override
  void paint(Canvas canvas, Size size) {
    if (cover) {
      if (next == backward) {
        frames.paintTurning(canvas, size);
      } else {
        frames.paintUnder(canvas);
      }
    } else if (frames.hasPreparedSlide) {
      canvas.drawPicture((next ? frames._slideTarget : frames._slideCurrent)!);
    } else {
      final image = (next == backward
          ? frames._turningImage
          : frames._underImage)!;
      paintReadingBackground(
        canvas,
        size,
        frames.paper,
        frames.backgroundImage,
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Offset.zero & size,
        SlideFramesPainter._pagePaint,
      );
    }
  }

  @override
  bool shouldRepaint(FlatFramePage old) =>
      old.frames != frames ||
      old.next != next ||
      old.backward != backward ||
      old.cover != cover;
}

/// 两张不透明纸面共享一条直缝。每帧只重放每张纸真正露出的部分。
class PreparedSlide extends StatelessWidget {
  const PreparedSlide(this.frames, this.offset, this.backward, this.width, {super.key});
  final FoldFrames frames;
  final double offset, width;
  final bool backward;

  @override
  Widget build(BuildContext context) => CustomPaint(
    willChange: true,
    painter: _PreparedSlidePainter(frames, offset, backward, width),
  );
}

class _PreparedSlidePainter extends CustomPainter {
  const _PreparedSlidePainter(this.frames, this.offset, this.backward, this.width);
  final FoldFrames frames;
  final double offset, width;
  final bool backward;

  @override
  void paint(Canvas canvas, Size size) {
    final seam = (backward ? offset : width + offset).clamp(0.0, size.width);
    void leaf(ui.Picture picture, double x, double left, double right) {
      if (left >= right) return;
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(left, 0, right, size.height),
        doAntiAlias: false,
      );
      canvas.translate(x, 0);
      canvas.drawPicture(picture);
      canvas.restore();
    }
    leaf(frames._slideCurrent!, offset,
        backward ? seam : 0, backward ? size.width : seam);
    leaf(frames._slideTarget!, offset + (backward ? -width : width),
        backward ? 0 : seam, backward ? seam : size.width);
  }

  @override
  bool shouldRepaint(_PreparedSlidePainter old) =>
      old.frames != frames || old.offset != offset ||
      old.backward != backward || old.width != width;
}

/// 两张原书截图首尾相接平移，保留整页边距、信息和书边，不裁切或缩小纹理。
class SlideFramesPainter extends CustomPainter {
  const SlideFramesPainter(this.frames, this.offset, this.backward);
  final FoldFrames frames;
  final double offset;
  final bool backward;
  // 两页共用一条直边；分别抗锯齿会让同一像素叠两次半透明边缘，
  // 仍漏出底下 WebView 的文字，形成随拖动断续变化的黑线。
  // 仅关闭整页矩形的边缘抗锯齿，保留截图滤镜、原尺寸和小数位移。
  static final _pagePaint = Paint()
    ..isAntiAlias = false
    ..filterQuality = FilterQuality.low;

  @override
  void paint(Canvas canvas, Size size) {
    final current = backward ? frames._underImage! : frames._turningImage!;
    final target = backward ? frames._turningImage! : frames._underImage!;
    void page(ui.Image image, double x) {
      // 单独给每页透明边缘补同位置的背景，防止露出静止文字或纯色细线。
      if (frames.backgroundImage != null) {
        canvas.save();
        canvas.translate(x, 0);
        canvas.clipRect(Offset.zero & size, doAntiAlias: false);
        paintReadingBackground(
          canvas,
          size,
          frames.paper,
          frames.backgroundImage,
        );
      }
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(
          frames.backgroundImage == null ? x : 0,
          0,
          size.width,
          size.height,
        ),
        _pagePaint,
      );
      if (frames.backgroundImage != null) canvas.restore();
    }

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // WebView 图层截图本身可能带透明边列（实机最后一列 alpha=0，
    // 前一列 alpha=191）；即使关闭矩形抗锯齿，也会透出静止网页的字。
    // 先铺完整纸色，仅填补原图的透明处，不裁图、不缩放或重画书边。
    canvas.drawColor(frames.paper, BlendMode.src);
    page(target, offset + (backward ? -size.width : size.width));
    page(current, offset);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SlideFramesPainter old) =>
      old.frames != frames || old.offset != offset || old.backward != backward;
}

/// 前翻把当前页向左移开，回翻由上一页从左侧盖入。
/// 底页保持静止；上下信息已经包含在整页绘制材料中。
class CoverFramesPainter extends CustomPainter {
  const CoverFramesPainter(this.frames, this.offset, this.backward);
  final FoldFrames frames;
  final double offset;
  final bool backward;

  @override
  void paint(Canvas canvas, Size size) {
    // 页叠不参与覆盖动画，位移和投影都以顶层纸面宽度计算。
    final leaf = frames.leafSize(size);
    final left = frames.coverLeft(size, offset, backward);
    final right = left + leaf.width;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.save();
    if (frames.preparedCurrent != null && frames.paper.a == 1) {
      // 顶页覆盖左侧。在接缝多留一个逻辑像素，右侧书边仍由底页绘制。
      canvas.clipRect(Rect.fromLTRB(right - 1, 0, size.width, size.height),
          doAntiAlias: false);
    }
    frames.paintUnder(canvas);
    canvas.restore();
    canvas.clipRect(Offset.zero & leaf);
    if (right > 0 && right < leaf.width) {
      final shadow = Rect.fromLTWH(right, 0, 10, size.height);
      canvas.drawRect(
        shadow,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0x33000000), Colors.transparent],
          ).createShader(shadow),
      );
    }
    canvas.translate(left, 0);
    frames.paintTurning(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(CoverFramesPainter old) =>
      old.frames != frames || old.offset != offset || old.backward != backward;
}

class FoldFramesPainter extends CustomPainter {
  const FoldFramesPainter(
    this.frames,
    this.progress,
    this.fromLeft,
    this.fromTop, {
    this.touchPosition,
    this.edgeCurl = false,
    this.edgeOriginY,
    this.settledTouch = false,
    this.currentInk,
    this.targetInk,
  });
  final FoldFrames frames;
  final double progress;
  final bool fromLeft;
  final bool fromTop;
  final Offset? touchPosition;
  final bool edgeCurl;
  final double? edgeOriginY;
  final bool settledTouch;
  final PageInk? currentInk, targetInk;

  FoldFramesPainter withInk(PageInk? current, PageInk? target) =>
      FoldFramesPainter(
        frames,
        progress,
        fromLeft,
        fromTop,
        touchPosition: touchPosition,
        edgeCurl: edgeCurl,
        edgeOriginY: edgeOriginY,
        settledTouch: settledTouch,
        currentInk: current,
        targetInk: target,
      );

  @override
  void paint(Canvas canvas, Size size) =>
      paintWithInk(canvas, size, current: currentInk, target: targetInk);

  Offset? _leafTouch(Size size, Size leaf) => touchPosition == null
      ? null
      : Offset(touchPosition!.dx * leaf.width / size.width, touchPosition!.dy);

  /// 背景和局部刷新都走同一折页入口，页码先画到原纸坐标，再与正文一起弯折。
  void paintWithInk(
    Canvas canvas,
    Size size, {
    PageInk? current,
    PageInk? target,
  }) {
    final spread = frames.spread;
    if (spread != null) {
      spread.paint(
        canvas,
        progress: progress,
        paper: frames.paper,
        fromTop: fromTop,
        touch: touchPosition,
        edgeCurl: edgeCurl,
        edgeY: edgeOriginY,
        currentInk: current,
        targetInk: target,
      );
      return;
    }
    final leaf = frames.leafSize(size);
    final turning = fromLeft ? target : current,
        under = fromLeft ? current : target;
    void paintUnder(Canvas c) {
      frames.paintUnder(c);
      under?.paint(c);
    }

    if (frames.bookEdges) {
      canvas.save();
      // 纸面内部由折页入口画底页。外层只补右侧页叠，保留1dp重叠，
      // 让纸面裁剪的抗锯齿像素仍叠在完整底色上，不产生细缝。
      canvas.clipRect(
        Rect.fromLTRB(leaf.width - 1, 0, size.width, size.height),
        doAntiAlias: false,
      );
      paintUnder(canvas);
      canvas.restore();
    }
    canvas.save();
    canvas.clipRect(Offset.zero & leaf);
    paintPageFold(
      canvas,
      leaf,
      progress: progress,
      fromLeft: fromLeft,
      fromTop: fromTop,
      edgeCurl: edgeCurl,
      touchPosition: _leafTouch(size, leaf),
      edgeOriginY: edgeOriginY,
      settledTouch: settledTouch,
      paper: frames.paper,
      turningImage: frames.turningImage,
      turningInk: turning == null ? null : LeafInk(turning, turning.bounds),
      underInk: under,
      paintTurningPage: (c) {
        frames.paintTurning(c, size);
        turning?.paint(c);
      },
      paintUnderPage: paintUnder,
      clipCoveredPaper: frames.preparedCurrent != null,
      texture: frames._curlTexture,
    );
    canvas.restore();
  }

  /// 只用于界定局部重绘范围。遮挡、纸背颜色和光照由 paintWithInk 实际绘制。
  Iterable<Rect> inkRegions(Size size, Rect band) sync* {
    yield band;
    final spread = frames.spread;
    if (spread != null) {
      final fold = spread
          .geometry(
            progress: progress,
            fromTop: fromTop,
            touch: touchPosition,
            edgeCurl: edgeCurl,
            edgeY: edgeOriginY,
          )
          .fold;
      if (fold == null) return;
      final r = fold.projectedBounds(spread.leftLeafBounds(band));
      yield Rect.fromLTWH(
        size.width / 2 + (fromLeft ? -r.right : r.left),
        r.top,
        r.width,
        r.height,
      );
      return;
    }
    final t = (fromLeft ? 1 - progress : progress).clamp(0.0, 1.0);
    if (t == 0 || t == 1) return;
    final leaf = frames.leafSize(size);
    final fold = pageFoldAt(
      leaf,
      t: t,
      fromLeft: fromLeft,
      fromTop: fromTop,
      edgeCurl: edgeCurl,
      touchPosition: _leafTouch(size, leaf),
      edgeOriginY: edgeOriginY,
      settledTouch: settledTouch,
    );
    if (fold != null) yield fold.projectedBounds(band);
  }

  @override
  bool shouldRepaint(FoldFramesPainter old) =>
      old.currentInk != currentInk ||
      old.targetInk != targetInk ||
      old.frames != frames ||
      old.progress != progress ||
      old.fromLeft != fromLeft ||
      old.fromTop != fromTop ||
      old.edgeCurl != edgeCurl ||
      old.edgeOriginY != edgeOriginY ||
      old.settledTouch != settledTouch ||
      old.touchPosition != touchPosition;
}
