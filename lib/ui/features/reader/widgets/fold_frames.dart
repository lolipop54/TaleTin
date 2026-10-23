import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'page_canvas.dart';
import 'spread_fold.dart';
import 'page_fold.dart';
import 'prepared_page.dart';
import 'page_raster_cache.dart';
import 'book_paper.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';

/// 一次手势冻结两页，动画结束或取消后统一释放。
class FoldFrames {
  FoldFrames(PreparedPage current, PreparedPage target, [this._rasterCache])
    : _current = current,
      _target = target,
      bookEdges = current.page.information?.bookEdges ?? false,
      paper = current.page.theme.background;
  FoldFrames.spread(
    ui.Image current,
    ui.Image target,
    Size size, {
    required bool backward,
    required this.paper,
    bool edges = false,
  }) : bookEdges = false,
       _current = null,
       _target = null,
       _rasterCache = null,
       spread = SpreadFold(current, target, size, backward, edges: edges);
  SpreadFold? spread;
  final PreparedPage? _current, _target;
  PreparedPage get current => _current!;
  PreparedPage get target => _target!;
  PreparedPage? get preparedCurrent => _current;
  PreparedPage? get preparedTarget => _target;
  final Color paper;
  final bool bookEdges;
  final PageRasterCache? _rasterCache;
  ui.Image? _underImage;
  bool get hasPageImages => _underImage != null;

  /// WebView 通过自身截图接口准备页面；图像随本次手势释放。
  FoldFrames.images(
    ui.Image current,
    ui.Image target,
    Size size, {
    required bool backward,
    required this.paper,
    this.bookEdges = false,
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
  ui.Picture? _underPicture;
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;

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
      if (curl) _prepareLeaf(size);
      return;
    }
    _turningImage = _rasterCache?.find(
      backward ? target : current,
      size,
      pixelRatio,
    );
    if (_turningImage == null) {
      final trace = ReaderWorkTrace.start('page.raster_image_sync', {
        'width': (size.width * pixelRatio).ceil(),
        'height': (size.height * pixelRatio).ceil(),
      });
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(pixelRatio);
      // 回翻上一页时，上一页展开盖回当前页，书脊仍在左侧。
      (backward ? target : current).paint(canvas, size);
      final picture = recorder.endRecording();
      try {
        _turningImage = picture.toImageSync(
          (size.width * pixelRatio).ceil(),
          (size.height * pixelRatio).ceil(),
        );
      } finally {
        picture.dispose();
        trace?.finish();
      }
    }
    final underRecorder = ui.PictureRecorder();
    (backward ? current : target).paint(Canvas(underRecorder), size);
    _underPicture = underRecorder.endRecording();
    if (curl) _prepareLeaf(size);
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
  }) async {
    // 空闲预备未赶上（例如立即跨章）时，也在启动动画前补齐文字指令。
    current.prepareText();
    target.prepareText();
    final pages = await Future.wait([
      PreparedPage.load(current, configuration),
      PreparedPage.load(target, configuration),
    ]);
    return FoldFrames(pages[0], pages[1], rasterCache);
  }

  void dispose() {
    spread?.dispose();
    _leafImage?.dispose();
    _turningImage?.dispose();
    _underPicture?.dispose();
    _underImage?.dispose();
    _current?.dispose();
    _target?.dispose();
  }
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
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(x, 0, size.width, size.height),
        _pagePaint,
      );
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
    final shift = offset * leaf.width / size.width;
    final left = (backward ? shift - leaf.width : shift).clamp(
      -leaf.width,
      0.0,
    );
    final right = left + leaf.width;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    frames.paintUnder(canvas);
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
  });
  final FoldFrames frames;
  final double progress;
  final bool fromLeft;
  final bool fromTop;
  final Offset? touchPosition;
  final bool edgeCurl;
  final double? edgeOriginY;
  final bool settledTouch;

  @override
  void paint(Canvas canvas, Size size) {
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
      );
      return;
    }
    final leaf = frames.leafSize(size);
    if (frames.bookEdges) {
      canvas.save();
      // 纸面内部由折页入口画底页。外层只补右侧页叠，保留1dp重叠，
      // 让纸面裁剪的抗锯齿像素仍叠在完整底色上，不产生细缝。
      canvas.clipRect(
        Rect.fromLTRB(leaf.width - 1, 0, size.width, size.height),
        doAntiAlias: false,
      );
      frames.paintUnder(canvas);
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
      touchPosition: touchPosition == null
          ? null
          : Offset(
              touchPosition!.dx * leaf.width / size.width,
              touchPosition!.dy,
            ),
      edgeOriginY: edgeOriginY,
      settledTouch: settledTouch,
      paper: frames.paper,
      turningImage: frames.turningImage,
      paintTurningPage: (c) => frames.paintTurning(c, size),
      paintUnderPage: frames.paintUnder,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(FoldFramesPainter old) =>
      old.frames != frames ||
      old.progress != progress ||
      old.fromLeft != fromLeft ||
      old.fromTop != fromTop ||
      old.edgeCurl != edgeCurl ||
      old.edgeOriginY != edgeOriginY ||
      old.settledTouch != settledTouch ||
      old.touchPosition != touchPosition;
}
