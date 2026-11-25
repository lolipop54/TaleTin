import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'page_ink.dart';

/// 正面与背面共用一个半圆柱。翻页纹理和独立页脚必须落到相同的弧面位置。
const foldStripCount = 24;
double projectedFoldDistance(double distance, double radius) =>
    -radius + 2 * radius / math.pi * math.sin(math.pi * (distance + radius) / (2 * radius));

/// 保留原来的 24 条卷曲带，将逐条裁切整页改成批量绘制三角形。
/// 先画正面再画背面，各自叠加原有明暗，避免背面被正面的阴影染色。
void paintFoldMesh(
  Canvas canvas,
  Size size,
  Image image,
  Color paper,
  Offset midpoint,
  Offset normal,
  double radius, {
  Image? backImage,
  LeafInk? frontInk,
  LeafInk? backInk,
}) {
  if (radius < 0.001) return;
  // 手指停住只刷新页脚时，离折痕很远的小窗口可以直接略过整个网格。
  final clipBounds = canvas.getLocalClipBounds();
  final center = clipBounds.center - midpoint;
  final d = center.dx * normal.dx + center.dy * normal.dy;
  final extent =
      (clipBounds.width * normal.dx.abs() +
          clipBounds.height * normal.dy.abs()) /
      2;
  if (d + extent < -radius - 1 ||
      d - extent > projectedFoldDistance(0, radius) + 1) {
    return;
  }
  final shader = ImageShader(
    image,
    TileMode.clamp,
    TileMode.clamp,
    Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
    filterQuality: FilterQuality.low,
  );
  final texture = Paint()..shader = shader;
  double distance(Offset p) =>
      (p.dx - midpoint.dx) * normal.dx + (p.dy - midpoint.dy) * normal.dy;
  List<Offset> clip(List<Offset> points, double edge, bool greater) {
    final result = <Offset>[];
    for (var i = 0; i < points.length; i++) {
      final a = points[i], b = points[(i + 1) % points.length];
      final da = distance(a) - edge, db = distance(b) - edge;
      final insideA = greater ? da >= 0 : da <= 0;
      final insideB = greater ? db >= 0 : db <= 0;
      if (insideA) result.add(a);
      if (insideA != insideB) result.add(a + (b - a) * (da / (da - db)));
    }
    return result;
  }

  for (var side = 0; side < 2; side++) {
    final selectedImage = side == 1 && backImage != null ? backImage : image;
    final backShader = side == 1 && backImage != null
        ? ImageShader(
            backImage,
            TileMode.clamp,
            TileMode.clamp,
            Float64List.fromList([
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              0,
              1,
            ]),
            filterQuality: FilterQuality.low,
          )
        : null;
    final sideTexture = backShader == null
        ? texture
        : (Paint()..shader = backShader);
    final positions = <Offset>[], coordinates = <Offset>[];
    final colors = <Color>[];
    for (var i = side * (foldStripCount ~/ 2); i < (side + 1) * (foldStripCount ~/ 2); i++) {
      final a = -radius + 2 * radius * i / foldStripCount;
      final b = -radius + 2 * radius * (i + 1) / foldStripCount;
      final rect = Offset.zero & size;
      final points = clip(
        clip(
          [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft],
          a,
          true,
        ),
        b,
        false,
      );
      final start = projectedFoldDistance(a, radius);
      final scale = (projectedFoldDistance(b, radius) - start) / (b - a);
      final bend = math.sin(math.pi * (i + 0.5) / foldStripCount);
      final shade = side == 0
          ? const Color(0xFF000000).withValues(alpha: bend * 0.24)
          : Color.alphaBlend(
              const Color(0xFFFFFFFF).withValues(alpha: bend * 0.18),
              paper.withValues(alpha: backImage == null ? 0.90 : 0),
            );
      // 裁切后的凸多边形拆成扇形三角形；纹理坐标仍对应原尺寸书页。
      for (var j = 1; j + 1 < points.length; j++) {
        for (final p in [points[0], points[j], points[j + 1]]) {
          final d = distance(p);
          positions.add(p + normal * (start + (d - a) * scale - d));
          coordinates.add(
            Offset(
              p.dx * selectedImage.width / size.width,
              p.dy * selectedImage.height / size.height,
            ),
          );
          colors.add(shade);
        }
      }
    }
    if (positions.isEmpty) {
      backShader?.dispose();
      continue;
    }
    final page = Vertices(
      VertexMode.triangles,
      positions,
      textureCoordinates: coordinates,
    );
    final shading = Vertices(VertexMode.triangles, positions, colors: colors);
    canvas.drawVertices(page, BlendMode.src, sideTexture);
    final ink = side == 0 ? frontInk : backInk;
    if (ink != null) {
      final area = ink.bounds;
      final d = distance(area.center);
      final extent =
          (normal.dx.abs() * area.width + normal.dy.abs() * area.height) / 2;
      if (d + extent >= (side == 0 ? -radius : 0) &&
          d - extent <= (side == 0 ? 0 : radius)) {
        // 同一批顶点依次取正文和局部透明笔迹，最后统一画纸背透色和弯折明暗。
        final inkShader = ink.shader(
          Size(selectedImage.width.toDouble(), selectedImage.height.toDouble()),
          size,
        );
        canvas.drawVertices(page, BlendMode.src, Paint()..shader = inkShader);
        inkShader.dispose();
      }
    }
    canvas.drawVertices(shading, BlendMode.dst, Paint());
    page.dispose();
    shading.dispose();
    backShader?.dispose();
  }
  shader.dispose();
}
