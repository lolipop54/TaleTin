import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cover_art_spec.dart';

/// 按封面样式绘制图形部分（不含文字）。
class CoverArtPainter extends CustomPainter {
  CoverArtPainter(this.spec);

  final CoverSpec spec;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 底色：纯色或纵向渐变
    canvas.drawRect(
      rect,
      Paint()
        ..shader = spec.backgroundEnd == null
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [spec.background, spec.backgroundEnd!],
              ).createShader(rect)
        ..color = spec.background,
    );
    switch (spec.art) {
      case CoverArt.moonSea:
        _moonSea(canvas, size);
      case CoverArt.brush:
        _brush(canvas, size);
      case CoverArt.forest:
        _forest(canvas, size);
      case CoverArt.botanical:
        _botanical(canvas, size);
      case CoverArt.skyVillage:
        _skyVillage(canvas, size);
      case CoverArt.starField:
        _starField(canvas, size);
      case CoverArt.inkTree:
        _inkTree(canvas, size);
      case CoverArt.shopWindow:
        _shopWindow(canvas, size);
      case CoverArt.island:
        _island(canvas, size);
      case CoverArt.foliage:
        _foliage(canvas, size);
      case CoverArt.geometric:
        _geometric(canvas, size);
      case CoverArt.street:
        _street(canvas, size);
    }
  }

  Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round;

  /// 月夜海面：圆月 + 海面反光。
  void _moonSea(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final moon = Offset(w * 0.62, h * 0.20);
    canvas.drawCircle(moon, w * 0.13, Paint()..color = spec.ink);
    // 月光在水面的纵向反光
    canvas.drawRect(
      Rect.fromLTWH(w * 0.56, h * 0.52, w * 0.12, h * 0.42),
      Paint()..color = spec.ink.withValues(alpha: 0.10),
    );
    // 海面横向波纹
    for (var i = 0; i < 12; i++) {
      final y = h * (0.55 + i * 0.033);
      final alpha = 0.30 - i * 0.017;
      canvas.drawLine(
        Offset(w * (0.06 + (i % 3) * 0.04), y),
        Offset(w * (0.94 - (i % 4) * 0.05), y),
        _stroke(spec.ink.withValues(alpha: alpha), 1),
      );
    }
  }

  /// 水墨留白：远山、屋脊与飞白（仿参考图「活着」的水墨封面）。
  void _brush(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // 远处淡墨山影
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.02, h * 0.74)
        ..quadraticBezierTo(w * 0.20, h * 0.62, w * 0.38, h * 0.73)
        ..quadraticBezierTo(w * 0.52, h * 0.80, w * 0.68, h * 0.72)
        ..lineTo(w * 0.68, h * 0.90)
        ..lineTo(w * 0.02, h * 0.90)
        ..close(),
      Paint()..color = spec.ink.withValues(alpha: 0.22),
    );
    // 近处浓墨屋脊群
    final ink = Paint()..color = spec.ink.withValues(alpha: 0.9);
    void roof(double cx, double baseY, double halfW, double roofH) {
      canvas.drawPath(
        Path()
          ..moveTo(cx - halfW, baseY)
          ..lineTo(cx, baseY - roofH)
          ..lineTo(cx + halfW, baseY)
          ..close(),
        ink,
      );
      canvas.drawRect(
          Rect.fromLTWH(cx - halfW * 0.86, baseY, halfW * 1.72, roofH * 0.62),
          ink);
    }

    roof(w * 0.20, h * 0.86, w * 0.13, h * 0.05);
    roof(w * 0.42, h * 0.88, w * 0.16, h * 0.065);
    roof(w * 0.60, h * 0.855, w * 0.11, h * 0.042);
    // 屋后一笔横向飞白
    canvas.drawLine(
      Offset(w * 0.06, h * 0.56),
      Offset(w * 0.48, h * 0.50),
      _stroke(spec.ink.withValues(alpha: 0.28), w * 0.05),
    );
    // 远处飞鸟
    for (final dx in [0.30, 0.40, 0.48]) {
      canvas.drawPath(
        Path()
          ..moveTo(w * dx, h * 0.38)
          ..quadraticBezierTo(
              w * (dx + 0.03), h * 0.355, w * (dx + 0.06), h * 0.38),
        _stroke(spec.ink.withValues(alpha: 0.55), w * 0.007),
      );
    }
  }

  /// 密林：深浅相间的树干。
  void _forest(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // 远处亮部
    for (var i = 0; i < 5; i++) {
      final x = w * (0.12 + i * 0.19);
      canvas.drawRect(
        Rect.fromLTWH(x, h * 0.18, w * 0.05, h * 0.82),
        Paint()..color = Colors.white.withValues(alpha: 0.06),
      );
    }
    // 近处树干
    for (var i = 0; i < 7; i++) {
      final x = w * (0.02 + i * 0.145);
      final tw = w * (i.isEven ? 0.055 : 0.035);
      canvas.drawRect(
        Rect.fromLTWH(x, h * 0.10 + (i % 3) * h * 0.03, tw, h * 0.90),
        Paint()..color = spec.ink.withValues(alpha: 0.55 + (i % 2) * 0.25),
      );
    }
  }

  /// 植物线描：一枝带叶的枝条。
  void _botanical(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stem = Path()
      ..moveTo(w * 0.22, h * 0.82)
      ..quadraticBezierTo(w * 0.40, h * 0.60, w * 0.52, h * 0.30);
    canvas.drawPath(stem, _stroke(spec.ink, w * 0.012));
    // 沿枝条的叶片
    for (var i = 0; i < 8; i++) {
      final t = 0.08 + i * 0.11;
      final x = w * (0.22 + (0.52 - 0.22) * t + 0.03);
      final y = h * (0.82 - (0.82 - 0.30) * t);
      final side = i.isEven ? 1 : -1;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(side * 0.9);
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(side * w * 0.05, 0),
            width: w * 0.11,
            height: w * 0.045),
        Paint()..color = spec.ink.withValues(alpha: 0.85),
      );
      canvas.restore();
    }
    // 根部小结
    canvas.drawCircle(Offset(w * 0.22, h * 0.82), w * 0.018,
        Paint()..color = spec.ink);
  }

  /// 天空与小镇：云、屋顶与暖色窗。
  void _skyVillage(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final cloud = Paint()..color = Colors.white.withValues(alpha: 0.55);
    for (final c in [
      Offset(w * 0.26, h * 0.16),
      Offset(w * 0.72, h * 0.24),
      Offset(w * 0.45, h * 0.30),
    ]) {
      canvas.drawCircle(c, w * 0.11, cloud);
      canvas.drawCircle(c.translate(w * 0.10, w * 0.02), w * 0.08, cloud);
      canvas.drawCircle(c.translate(-w * 0.09, w * 0.03), w * 0.07, cloud);
    }
    // 地面
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.80, w, h * 0.20),
      Paint()..color = const Color(0xFF8FB98A),
    );
    // 房屋
    final house = Paint()..color = const Color(0xFFF0E6D2);
    canvas.drawRect(Rect.fromLTWH(w * 0.30, h * 0.70, w * 0.40, h * 0.12), house);
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.26, h * 0.70)
        ..lineTo(w * 0.50, h * 0.60)
        ..lineTo(w * 0.74, h * 0.70)
        ..close(),
      Paint()..color = const Color(0xFFD98C6A),
    );
    // 窗
    final win = Paint()..color = const Color(0xFF7E6A48);
    canvas.drawRect(Rect.fromLTWH(w * 0.38, h * 0.74, w * 0.08, h * 0.05), win);
    canvas.drawRect(Rect.fromLTWH(w * 0.54, h * 0.74, w * 0.08, h * 0.05), win);
  }

  /// 星野：星空、行星与小小的人影。
  void _starField(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // 固定种子保证每次绘制一致
    final rnd = math.Random(7);
    final star = Paint()..color = spec.ink;
    for (var i = 0; i < 46; i++) {
      final x = rnd.nextDouble() * w;
      final y = rnd.nextDouble() * h * 0.78;
      final r = rnd.nextDouble() * w * 0.008 + w * 0.003;
      canvas.drawCircle(Offset(x, y), r, star);
    }
    // 行星与光晕
    final planet = Offset(w * 0.86, h * 0.16);
    canvas.drawCircle(planet, w * 0.20,
        Paint()..color = spec.ink.withValues(alpha: 0.10));
    canvas.drawCircle(planet, w * 0.13,
        Paint()..color = spec.ink.withValues(alpha: 0.22));
    // 地平线
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.80, w, h * 0.20),
      Paint()..color = const Color(0xFF070A10),
    );
    // 人影
    final person = Paint()..color = const Color(0xFF060809);
    canvas.drawCircle(Offset(w * 0.46, h * 0.735), w * 0.02, person);
    canvas.drawRect(Rect.fromLTWH(w * 0.447, h * 0.755, w * 0.027, h * 0.05), person);
  }

  /// 水墨树影：枝干、点叶与长椅。
  void _inkTree(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final ink = spec.ink;
    // 主干与分枝
    final trunk = Path()
      ..moveTo(w * 0.40, h * 0.74)
      ..quadraticBezierTo(w * 0.36, h * 0.56, w * 0.44, h * 0.42)
      ..quadraticBezierTo(w * 0.50, h * 0.32, w * 0.46, h * 0.22);
    canvas.drawPath(trunk, _stroke(ink.withValues(alpha: 0.9), w * 0.022));
    final branch = Path()
      ..moveTo(w * 0.43, h * 0.50)
      ..quadraticBezierTo(w * 0.58, h * 0.44, w * 0.70, h * 0.34);
    canvas.drawPath(branch, _stroke(ink.withValues(alpha: 0.8), w * 0.014));
    final branch2 = Path()
      ..moveTo(w * 0.44, h * 0.40)
      ..quadraticBezierTo(w * 0.30, h * 0.34, w * 0.22, h * 0.26);
    canvas.drawPath(branch2, _stroke(ink.withValues(alpha: 0.7), w * 0.012));
    // 点叶
    final rnd = math.Random(3);
    final leaf = Paint()..color = ink.withValues(alpha: 0.55);
    for (var i = 0; i < 40; i++) {
      final x = w * (0.16 + rnd.nextDouble() * 0.60);
      final y = h * (0.14 + rnd.nextDouble() * 0.42);
      canvas.drawCircle(Offset(x, y), w * 0.012 * (0.6 + rnd.nextDouble()), leaf);
    }
    // 地面线与长椅
    canvas.drawLine(Offset(w * 0.12, h * 0.80), Offset(w * 0.88, h * 0.80),
        _stroke(ink.withValues(alpha: 0.35), 1));
    final bench = Paint()..color = ink.withValues(alpha: 0.8);
    canvas.drawRect(Rect.fromLTWH(w * 0.52, h * 0.76, w * 0.30, h * 0.018), bench);
    canvas.drawRect(Rect.fromLTWH(w * 0.54, h * 0.78, w * 0.012, h * 0.035), bench);
    canvas.drawRect(Rect.fromLTWH(w * 0.78, h * 0.78, w * 0.012, h * 0.035), bench);
  }

  /// 夜色橱窗：亮着的窗与吊灯（窗偏下，给上方书名留位）。
  void _shopWindow(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // 窗框
    final frame = Rect.fromLTWH(w * 0.16, h * 0.50, w * 0.68, h * 0.34);
    canvas.drawRect(frame, Paint()..color = spec.ink.withValues(alpha: 0.92));
    // 窗内暖光渐变（顶部亮、底部暗）
    canvas.drawRect(
      frame.deflate(w * 0.022),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFF6D79A),
            spec.ink.withValues(alpha: 0.85),
          ],
        ).createShader(frame),
    );
    // 竖框与横框
    final mullion = Paint()..color = const Color(0xFF22314A);
    canvas.drawRect(
        Rect.fromLTWH(w * 0.49, frame.top, w * 0.022, frame.height), mullion);
    canvas.drawRect(
        Rect.fromLTWH(frame.left, h * 0.66, frame.width, h * 0.012), mullion);
    // 吊灯
    canvas.drawLine(Offset(w * 0.50, h * 0.36), Offset(w * 0.50, h * 0.48),
        _stroke(const Color(0xFF22314A), w * 0.008));
    canvas.drawCircle(Offset(w * 0.50, h * 0.49), w * 0.045,
        Paint()..color = const Color(0xFFF3D28F).withValues(alpha: 0.9));
    // 窗下货架剪影与地面
    canvas.drawRect(Rect.fromLTWH(0, h * 0.86, w, h * 0.14),
        Paint()..color = const Color(0xFF0B1424));
    canvas.drawRect(Rect.fromLTWH(w * 0.10, h * 0.845, w * 0.80, h * 0.012),
        Paint()..color = const Color(0xFF16233A));
  }

  /// 远岛海面：海平线、小岛与飞鸟。
  void _island(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // 海面
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.58, w, h * 0.20),
      Paint()..color = spec.ink.withValues(alpha: 0.42),
    );
    for (var i = 0; i < 7; i++) {
      final y = h * (0.61 + i * 0.026);
      canvas.drawLine(Offset(w * 0.04, y), Offset(w * (0.46 + i * 0.08), y),
          _stroke(spec.ink.withValues(alpha: 0.65), 1.2));
    }
    // 小岛
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.28, h * 0.60)
        ..quadraticBezierTo(w * 0.42, h * 0.46, w * 0.58, h * 0.60)
        ..close(),
      Paint()..color = spec.ink.withValues(alpha: 0.85),
    );
    // 飞鸟
    for (final dx in [0.66, 0.74, 0.62]) {
      final p = Path()
        ..moveTo(w * dx, h * 0.40)
        ..quadraticBezierTo(w * (dx + 0.03), h * 0.375, w * (dx + 0.06), h * 0.40);
      canvas.drawPath(p, _stroke(spec.ink, w * 0.008));
    }
  }

  /// 叶片纹样：满版叶子平铺。
  void _foliage(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rnd = math.Random(11);
    for (var i = 0; i < 34; i++) {
      final x = rnd.nextDouble() * w;
      final y = rnd.nextDouble() * h;
      final ang = rnd.nextDouble() * math.pi;
      final scale = 0.5 + rnd.nextDouble() * 0.8;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(ang);
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset.zero, width: w * 0.24 * scale, height: w * 0.09 * scale),
        Paint()
          ..color = spec.ink.withValues(alpha: 0.28 + rnd.nextDouble() * 0.35),
      );
      canvas.restore();
    }
  }

  /// 几何抽象：几块交叠的色面。
  void _geometric(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.06, h * 0.10)
        ..lineTo(w * 0.62, h * 0.04)
        ..lineTo(w * 0.30, h * 0.46)
        ..close(),
      Paint()..color = spec.ink.withValues(alpha: 0.92),
    );
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.44, h * 0.30)
        ..lineTo(w * 0.98, h * 0.22)
        ..lineTo(w * 0.66, h * 0.62)
        ..close(),
      Paint()..color = spec.ink.withValues(alpha: 0.45),
    );
    canvas.drawRect(
      Rect.fromLTWH(w * 0.10, h * 0.52, w * 0.52, h * 0.18),
      Paint()..color = spec.ink.withValues(alpha: 0.22),
    );
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.30, h * 0.86)
        ..lineTo(w * 0.92, h * 0.78)
        ..lineTo(w * 0.86, h * 0.98)
        ..lineTo(w * 0.22, h * 0.98)
        ..close(),
      Paint()..color = spec.ink.withValues(alpha: 0.70),
    );
  }

  /// 街景：楼群与行人。
  void _street(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rnd = math.Random(5);
    // 楼群
    for (var i = 0; i < 6; i++) {
      final x = w * (i * 0.17);
      final bw = w * (0.13 + rnd.nextDouble() * 0.07);
      final bh = h * (0.34 + rnd.nextDouble() * 0.30);
      final top = h * 0.86 - bh;
      canvas.drawRect(
        Rect.fromLTWH(x, top, bw, bh),
        Paint()..color = spec.ink.withValues(alpha: 0.35 + rnd.nextDouble() * 0.35),
      );
      // 窗
      final win = Paint()..color = const Color(0xFFF3F1EA).withValues(alpha: 0.75);
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 2; c++) {
          canvas.drawRect(
            Rect.fromLTWH(x + bw * (0.18 + c * 0.42), top + bh * (0.12 + r * 0.20),
                bw * 0.22, bh * 0.07),
            win,
          );
        }
      }
    }
    // 街道
    canvas.drawRect(Rect.fromLTWH(0, h * 0.86, w, h * 0.14),
        Paint()..color = spec.ink.withValues(alpha: 0.55));
    // 行人
    final person = Paint()..color = const Color(0xFF2B2B2E);
    canvas.drawCircle(Offset(w * 0.34, h * 0.845), w * 0.018, person);
    canvas.drawRect(Rect.fromLTWH(w * 0.328, h * 0.862, w * 0.025, h * 0.045), person);
    canvas.drawCircle(Offset(w * 0.55, h * 0.850), w * 0.016, person);
    canvas.drawRect(Rect.fromLTWH(w * 0.539, h * 0.866, w * 0.022, h * 0.040), person);
  }

  @override
  bool shouldRepaint(CoverArtPainter oldDelegate) =>
      oldDelegate.spec != spec;
}
