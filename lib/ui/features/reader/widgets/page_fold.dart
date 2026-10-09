import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'page_fold_mesh.dart';

/// 折痕是原角点与拖动后角点连线的垂直平分线。
/// 只计算单页几何，不参与分页、手势提交或阅读位置存储。
class PageFold {
  PageFold({required this.size, required Offset corner, required Offset touch})
    : assert(corner != touch),
      midpoint = (corner + touch) / 2,
      _foldDepth = (corner - touch).distance / 2,
      normal = (corner - touch) / (corner - touch).distance;

  final Size size;
  final Offset midpoint;
  final Offset normal;
  final double _foldDepth;

  /// 点按上下区域时，书角先抬起再翻过；两端高度归零，落页不跳变。
  static Offset tapCornerTouch(Size size, double progress,
      {required bool backward, required bool fromTop}) {
    final t = backward ? 1 - progress : progress;
    final lift = size.shortestSide * 0.28 * 4 * t * (1 - t);
    return Offset(size.width * (1 - 2 * t),
        fromTop ? lift : size.height - lift);
  }

  /// 展平时倾斜量比横向距离更快归零，避免折痕保持斜率直到最后一帧。
  static Offset settleTouch(Offset from, Offset to, double t,
      {required bool unfolded}) {
    final point = Offset.lerp(from, to, t)!;
    return unfolded
        ? Offset(point.dx, to.dy + (point.dy - to.dy) * (1 - t))
        : point;
  }

  /// 两个方向都绕左侧书脊；回翻把上一页从左侧展开。
  static Offset dragTouch(
    Size size,
    Offset corner,
    Offset finger, {
    required bool backward,
    required bool edgeCurl,
  }) {
    if (edgeCurl) {
      // corner 是右侧纸边上起手高度的点，反射后才是自由纸边，
      // 不能把圆柱最凸处当作纸边。左右翻动共用同一自由边坐标。
      final x = finger.dx
          .clamp(-size.width, size.width).toDouble();
      final tilt = (size.width - x) * 0.20;
      // 同时约束到书脊两个端点的距离，倾斜时整条书脊都不能被拉走。
      final reach = size.width * size.width - x * x;
      final low = size.height - math.sqrt(reach +
          math.pow(size.height - corner.dy, 2));
      final high = math.sqrt(reach + corner.dy * corner.dy);
      final y = (corner.dy + (finger.dy - corner.dy).clamp(-tilt, tilt))
          .clamp(math.max(0.0, low), math.min(size.height, high)).toDouble();
      return Offset(x, y);
    }
    return constrainTouch(
      size,
      corner,
      finger,
    );
  }

  /// 半圆柱卷曲带的上限随短边变化，避免不同屏幕上看起来都是一道硬折线。
  static double maxCurlWidth(Size size) => size.shortestSide * 0.10;

  /// 书角到书脊的距离受纸张长度限制，还要给弧面留下长度。
  /// 横向位置确定后限制抬起高度，超过极限继续上拖不会把书角缩回去。
  static Offset constrainTouch(Size size, Offset corner, Offset touch) {
    final radius = maxCurlWidth(size);
    final side = corner.dx == 0 ? 1.0 : -1.0;
    final inward = ((touch.dx - corner.dx) * side)
        .clamp(0.0, 2 * (size.width - radius));
    // 设角点移动距离为 d，折痕到书脊余量需 >= min(radius, d / 6)。
    // 解出 d 的上限，再由横向位移求可抬起的高度，始终保留装订边。
    final smallBend = math.sqrt(1.5 * size.width * inward);
    final distanceLimit = smallBend <= 6 * radius ? smallBend
        : math.sqrt(radius * radius + 2 * size.width * inward) - radius;
    final heightLimit = math.min(size.shortestSide,
        math.sqrt(math.max(0.0, distanceLimit * distanceLimit - inward * inward)));
    return Offset(corner.dx + side * inward, touch.dy.clamp(
      math.max(0.0, corner.dy - heightLimit),
      math.min(size.height, corner.dy + heightLimit)));
  }

  /// 卷曲带在起手、拉紧书脊和翻完时收窄，不带动装订边。
  double get curlWidth {
    final spineX = normal.dx > 0 ? 0.0 : size.width;
    final clearance = -math.max(
      _distance(Offset(spineX, 0)),
      _distance(Offset(spineX, size.height)),
    );
    return math.max(
      0,
      math.min(
        math.min(maxCurlWidth(size), _foldDepth / 3),
        math.min(
          clearance,
          _distance(
                Offset(
                  normal.dx > 0 ? size.width : 0,
                  normal.dy > 0 ? size.height : 0,
                ),
              ) /
              3,
        ),
      ),
    );
  }

  double _distance(Offset p) =>
      (p.dx - midpoint.dx) * normal.dx + (p.dy - midpoint.dy) * normal.dy;

  /// 反射后角点落在手指处，折痕上的点保持原位。
  Offset reflect(Offset p) => p - normal * (2 * _distance(p));

  Path get front => _clip(folded: false, boundary: -curlWidth);
  Path get flap => _clip(folded: true, boundary: curlWidth);
  Path get back => flap.transform(reflection);

  Float64List get reflection {
    final x = normal.dx;
    final y = normal.dy;
    final d = midpoint.dx * x + midpoint.dy * y;
    return Float64List.fromList([
      1 - 2 * x * x,
      -2 * x * y,
      0,
      0,
      -2 * x * y,
      1 - 2 * y * y,
      0,
      0,
      0,
      0,
      1,
      0,
      2 * d * x,
      2 * d * y,
      0,
      1,
    ]);
  }

  /// 用折痕裁切页面矩形，兼容折痕穿过任意两条边的情况。
  Path _clip({required bool folded, double boundary = 0}) {
    final rect = Offset.zero & size;
    final vertices = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];
    final points = <Offset>[];
    for (var i = 0; i < vertices.length; i++) {
      final a = vertices[i];
      final b = vertices[(i + 1) % vertices.length];
      final da = _distance(a) - boundary;
      final db = _distance(b) - boundary;
      final insideA = folded ? da >= 0 : da <= 0;
      final insideB = folded ? db >= 0 : db <= 0;
      if (insideA) points.add(a);
      if (insideA != insideB) points.add(a + (b - a) * (da / (da - db)));
    }
    return Path()..addPolygon(points, true);
  }
}

/// 共用折页绘制入口；两个回调必须同步画出已经准备好的完整页面。
/// Flutter 正文可直接绘制；WebView 必须先取得页面图像，不能直接画平台视图。
void paintPageFold(
  Canvas canvas,
  Size size, {
  required double progress,
  required bool fromLeft,
  required bool fromTop,
  bool edgeCurl = false,
  Offset? touchPosition,
  double? edgeOriginY,
  bool settledTouch = false,
  required Color paper,
  required void Function(Canvas) paintTurningPage,
  required void Function(Canvas) paintUnderPage,
  Image? turningImage,
}) {
  // 回翻时翻动的是上一页：从完全折起到展开，当前页留在下面。
  final t = (fromLeft ? 1 - progress : progress).clamp(0.0, 1.0);
  final rect = Offset.zero & size;
  if (size.isEmpty) return;
  canvas.save();
  canvas.clipRect(rect);
  // 端点单独画整页，避免零长度法向量与完成时残留一条纸边。
  if (t == 0 || t == 1) {
    canvas.drawRect(rect, Paint()..color = paper);
    (t == 0 ? paintTurningPage : paintUnderPage)(canvas);
    canvas.restore();
    return;
  }
  final corner = Offset(size.width, edgeCurl
      ? (edgeOriginY ?? size.height / 2) : (fromTop ? 0 : size.height));
  // 中段倾斜、末段展平；拖到两倍页宽时整张纸离开可视区。
  final touch = touchPosition != null
      ? settledTouch ? touchPosition : PageFold.dragTouch(
          size,
          corner,
          touchPosition,
          backward: fromLeft,
          edgeCurl: edgeCurl,
        )
      : PageFold.constrainTouch(
          size,
          corner,
          corner +
              Offset(
                -2 * size.width * t,
                (fromTop ? 1 : -1) * size.height * 0.18 * 4 * t * (1 - t),
              ),
        );
  if (touch == corner) {
    canvas.drawRect(rect, Paint()..color = paper);
    paintTurningPage(canvas);
    canvas.restore();
    return;
  }
  final fold = PageFold(size: size, corner: corner, touch: touch);
  final recorder = PictureRecorder();
  final pageCanvas = Canvas(recorder);
  pageCanvas.drawRect(rect, Paint()..color = paper);
  paintTurningPage(pageCanvas);
  final page = recorder.endRecording();
  canvas.drawRect(rect, Paint()..color = paper);
  paintUnderPage(canvas);
  // 弧面向底页投下渐淡的阴影；使用渐变而非额外模糊离屏层。
  final r = fold.curlWidth;
  if (r > 0.001) {
    canvas.drawRect(rect, Paint()..shader = Gradient.linear(
      fold.midpoint - fold.normal * r,
      fold.midpoint + fold.normal * (r * 0.65),
      const [Color(0x30000000), Color(0x00000000)],
    ));
  }
  canvas.save();
  canvas.clipPath(fold.front);
  canvas.drawPicture(page);
  canvas.restore();
  // 投影随卷曲高度变化，展平时连续收回，不留下固定宽度的黑边。
  canvas.drawShadow(fold.back, const Color(0x80000000),
      fold.curlWidth * 0.50, false);
  canvas.save();
  canvas.clipPath(fold.back);
  canvas.transform(fold.reflection);
  canvas.drawPicture(page);
  // 纸背保留淡淡的镜像正文，颜色沿用当前阅读主题。
  canvas.drawRect(rect, Paint()..color = paper.withValues(alpha: 0.90));
  canvas.restore();
  if (turningImage == null) {
    _paintCurl(canvas, size, fold, page, paper);
  } else {
    paintFoldMesh(canvas, size, turningImage, paper,
        fold.midpoint, fold.normal, fold.curlWidth);
  }
  page.dispose();
  canvas.restore();
}

/// 把折痕两侧映射为半圆柱；先画正面再画纸背，纸边与文字一起弯曲。
void _paintCurl(
  Canvas canvas,
  Size size,
  PageFold fold,
  Picture page,
  Color paper,
) {
  final r = fold.curlWidth;
  if (r < 0.001) return;
  final angle = math.atan2(fold.normal.dy, fold.normal.dx);
  final extent = size.longestSide * 3;
  const strips = 24;
  for (var i = 0; i < strips; i++) {
    final a = -r + 2 * r * i / strips;
    final b = -r + 2 * r * (i + 1) / strips;
    // 用条带端点拟合，接缝共享投影位置，避免条带之间出现空隙。
    double project(double d) =>
        -r + 2 * r / math.pi * math.sin(math.pi * (d + r) / (2 * r));
    final scale = (project(b) - project(a)) / (b - a);
    canvas.save();
    canvas.translate(fold.midpoint.dx, fold.midpoint.dy);
    canvas.rotate(angle);
    canvas.translate(project(a) - scale * a, 0);
    canvas.scale(scale, 1);
    canvas.clipRect(Rect.fromLTRB(a, -extent, b, extent), doAntiAlias: false);
    canvas.rotate(-angle);
    canvas.translate(-fold.midpoint.dx, -fold.midpoint.dy);
    canvas.clipRect(Offset.zero & size);
    canvas.drawPicture(page);
    if (i >= strips ~/ 2) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = paper.withValues(alpha: 0.90),
      );
    }
    final bend = math.sin(math.pi * (i + 0.5) / strips);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color =
            (i < strips ~/ 2
                    ? const Color(0xFF000000)
                    : const Color(0xFFFFFFFF))
                .withValues(alpha: bend * (i < strips ~/ 2 ? 0.24 : 0.18)),
    );
    canvas.restore();
  }
}
