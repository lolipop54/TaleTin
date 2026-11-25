import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'page_fold.dart';
import 'page_ink.dart';
import 'book_paper.dart';
import 'page_fold_mesh.dart';

/// 复用单页折痕与卷曲网格，仅改变纸张的装订位置和正反面内容。
/// 四张逻辑页在起手时冻结；绘制过程中不读WebView、不重新分页。
class SpreadFold {
  SpreadFold(
    this.current,
    this.target,
    this.size,
    this.backward, {
    this.edges = false,
  }) {
    final half = size.width / 2;
    front = _crop(current, backward ? inset : half, mirror: backward);
    back = _crop(target, backward ? half : inset, mirror: !backward);
  }
  final ui.Image current, target;
  final Size size;
  final bool backward, edges;
  double get inset => edges ? bookEdgeWidth : 0;
  Size get leafSize => Size(size.width / 2 - inset, size.height);

  /// 正翻与回翻在同一张纸的坐标里计算，中缝是 x=0，页叠不算入纸宽。
  Offset boundCornerTouch(Offset touch, {required bool fromTop}) {
    final leaf = leafSize;
    return PageFold.constrainTouch(
      leaf,
      Offset(leaf.width, fromTop ? 0 : leaf.height),
      touch,
      allowFullTurn: true,
    );
  }

  late final ui.Image front, back;
  final _paint = Paint()..filterQuality = FilterQuality.low;
  ui.Image _crop(ui.Image source, double x, {required bool mirror}) {
    final ratio = source.width / size.width;
    final width = ((size.width / 2 - inset) * ratio).round();
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    if (mirror) {
      c.translate(width.toDouble(), 0);
      c.scale(-1, 1);
    }
    c.drawImageRect(
      source,
      Rect.fromLTWH(x * ratio, 0, width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), source.height.toDouble()),
      _paint,
    );
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, source.height);
    } finally {
      picture.dispose();
    }
  }

  void _full(Canvas c, ui.Image image) => c.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    _paint,
  );
  ({PageFold? fold, bool target}) geometry({required double progress, required bool fromTop,
    Offset? touch, bool edgeCurl = false, double? edgeY}) {
    final half = size.width / 2;
    final leaf = leafSize;
    final corner = Offset(
      leaf.width,
      edgeCurl
          ? edgeY ?? leaf.height / 2
          : fromTop
          ? 0
          : leaf.height,
    );
    final point = edgeCurl
        ? Offset(
            touch == null
                ? leaf.width * (1 - 2 * progress)
                : touch.dx * leaf.width / half,
            touch?.dy ?? corner.dy,
          )
        : boundCornerTouch(
            touch ??
                PageFold.tapCornerTouch(
                  leaf,
                  progress,
                  backward: false,
                  fromTop: fromTop,
                ),
            fromTop: fromTop,
          );
    if ((point - corner).distance < .01) return (fold: null, target: false);
    if (point.dx <= -leaf.width + .01 && (point.dy - corner.dy).abs() < .01) {
      return (fold: null, target: true);
    }
    return (fold: PageFold(size: leaf, corner: corner, touch: point), target: false);
  }

  void paint(
    Canvas canvas, {
    required double progress,
    required Color paper,
    required bool fromTop,
    Offset? touch,
    bool edgeCurl = false,
    double? edgeY,
    PageInk? currentInk,
    PageInk? targetInk,
  }) {
    final half = size.width / 2;
    final leaf = leafSize;
    final frame = geometry(progress: progress, fromTop: fromTop, touch: touch,
        edgeCurl: edgeCurl, edgeY: edgeY);
    final fold = frame.fold;
    if (fold == null) {
      _full(canvas, frame.target ? target : current);
      (frame.target ? targetInk : currentInk)?.paint(canvas);
      return;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _full(canvas, current);
    currentInk?.paint(canvas);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(backward ? 0 : half, 0, half, leaf.height));
    _full(canvas, target);
    targetInk?.paint(canvas);
    canvas.restore();
    if (backward) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.clipRect(Rect.fromLTRB(inset, 0, size.width - inset, size.height));
    canvas.translate(half, 0);
    // 允许纸背越过书沟落到另一侧；单页算法的外层裁剪不能沿用到这里。
    void image(ui.Image i) => canvas.drawImageRect(
      i,
      Rect.fromLTWH(0, 0, i.width.toDouble(), i.height.toDouble()),
      Offset.zero & leaf,
      _paint,
    );
    // 页码在整组纸的左下角。左半页在裁出的卷页纹理中是镜像坐标。
    final frontInk = backward ? toLeftLeaf(currentInk) : null;
    final backInk = backward ? null : toLeftLeaf(targetInk);
    canvas.drawShadow(
      fold.back,
      const Color(0x80000000),
      fold.curlWidth * .5,
      false,
    );
    canvas.save();
    canvas.clipPath(fold.front);
    image(front);
    frontInk?.paint(canvas);
    canvas.restore();
    canvas.save();
    canvas.clipPath(fold.back);
    canvas.transform(fold.reflection);
    image(back);
    backInk?.paint(canvas);
    canvas.restore();
    paintFoldMesh(
      canvas,
      leaf,
      front,
      paper,
      fold.midpoint,
      fold.normal,
      fold.curlWidth,
      backImage: back,
      frontInk: frontInk,
      backInk: backInk,
    );
    canvas.restore();
  }

  Rect leftLeafBounds(Rect band) => Rect.fromLTWH(
    size.width / 2 - band.right,
    band.top,
    band.width,
    band.height,
  );
  LeafInk? toLeftLeaf(PageInk? ink) => ink == null
      ? null
      : LeafInk(ink, leftLeafBounds(ink.bounds), mirror: true);

  void dispose() {
    current.dispose();
    target.dispose();
    front.dispose();
    back.dispose();
  }
}
