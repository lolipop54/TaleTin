import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'page_canvas.dart';
import 'page_fold.dart';
import 'prepared_page.dart';

/// 一次手势冻结两页，动画结束或取消后统一释放。
class FoldFrames {
  FoldFrames(PreparedPage current, PreparedPage target)
      : _current = current, _target = target, paper = current.page.theme.background;
  final PreparedPage? _current, _target;
  PreparedPage get current => _current!;
  PreparedPage get target => _target!;
  PreparedPage? get preparedCurrent => _current;
  PreparedPage? get preparedTarget => _target;
  final Color paper;
  ui.Image? _underImage;

  /// WebView 通过自身截图接口准备页面；图像随本次手势释放。
  FoldFrames.images(ui.Image current, ui.Image target, Size size,
      {required bool backward, required this.paper}) : _current = null, _target = null {
    _turningImage = backward ? target : current;
    _underImage = backward ? current : target;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(_underImage!,
      Rect.fromLTWH(0, 0, _underImage!.width.toDouble(), _underImage!.height.toDouble()),
      Offset.zero & size, _imagePaint);
    _underPicture = recorder.endRecording();
  }
  ui.Image? _turningImage;
  ui.Image get turningImage => _turningImage!;
  ui.Picture? _underPicture;
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;

  /// 每次手势只生成一次；按屏幕像素密度缓存，卷曲时不重复绘制字形。
  /// toImageSync 返回 GPU 图像句柄，光栅化由引擎排队完成，不回读 CPU。
  void preparePainting(Size size, double pixelRatio, {bool backward = false}) {
    if (_turningImage != null) return;
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
    }
    final underRecorder = ui.PictureRecorder();
    (backward ? current : target).paint(Canvas(underRecorder), size);
    _underPicture = underRecorder.endRecording();
  }

  void paintTurning(Canvas canvas, Size size) {
    final image = _turningImage!;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      _imagePaint,
    );
  }

  void paintUnder(Canvas canvas) => canvas.drawPicture(_underPicture!);

  static Future<FoldFrames> load(
    PageCanvas current,
    PageCanvas target,
    ImageConfiguration configuration,
  ) async {
    final pages = await Future.wait([
      PreparedPage.load(current, configuration),
      PreparedPage.load(target, configuration),
    ]);
    return FoldFrames(pages[0], pages[1]);
  }

  void dispose() {
    _turningImage?.dispose();
    _underPicture?.dispose();
    _underImage?.dispose();
    _current?.dispose();
    _target?.dispose();
  }
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
    final left = (backward ? offset - size.width : offset).clamp(-size.width, 0.0);
    final right = left + size.width;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    frames.paintUnder(canvas);
    if (right > 0 && right < size.width) {
      final shadow = Rect.fromLTWH(right, 0, 10, size.height);
      canvas.drawRect(shadow, Paint()..shader = const LinearGradient(
        colors: [Color(0x33000000), Colors.transparent],
      ).createShader(shadow));
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
  void paint(Canvas canvas, Size size) => paintPageFold(
    canvas,
    size,
    progress: progress,
    fromLeft: fromLeft,
    fromTop: fromTop,
    edgeCurl: edgeCurl,
    touchPosition: touchPosition,
    edgeOriginY: edgeOriginY,
    settledTouch: settledTouch,
    paper: frames.paper,
    turningImage: frames.turningImage,
    paintTurningPage: (c) => frames.paintTurning(c, size),
    paintUnderPage: frames.paintUnder,
  );

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
