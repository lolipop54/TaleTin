import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 固定蓝布与纸签只在资源准备时画一次，所有秘籍封面共享栅格图。
void paintMartialCoverBackground(Canvas canvas) {
  final random = math.Random(74);
  const bounds = Rect.fromLTWH(0, 0, 284, 400);
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = const RadialGradient(
        center: Alignment(.35, .05),
        radius: 1.05,
        colors: [Color(0xff123e80), Color(0xff082652), Color(0xff061a39)],
      ).createShader(bounds),
  );
  for (var i = 0; i < 3800; i++) {
    final point = Offset(random.nextDouble() * 284, random.nextDouble() * 400);
    canvas.drawLine(
      point,
      point + const Offset(1.8, .4),
      Paint()
        ..color = Colors.white.withValues(alpha: random.nextDouble() * .055)
        ..strokeWidth = .45,
    );
  }
  canvas.drawRect(
    const Rect.fromLTWH(8, 0, 4, 400),
    Paint()..color = Colors.black26,
  );
  final thread = Paint()
    ..color = const Color(0xfff7f3df)
    ..strokeWidth = 1.65;
  canvas.drawLine(const Offset(26, 0), const Offset(28, 400), thread);
  for (final y in [39.0, 144.0, 242.0, 335.0]) {
    for (final delta in [-1.7, 1.7]) {
      canvas.drawLine(Offset(0, y + delta + 2), Offset(27, y + delta), thread);
    }
  }
  const label = Rect.fromLTWH(205, 23, 63, 318);
  canvas.drawRect(
    label,
    Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xffd6b77a), Color(0xfff0e3b7), Color(0xffe5d09a)],
      ).createShader(label),
  );
  canvas.drawRect(
    label.deflate(3),
    Paint()
      ..color = const Color(0xffad8247)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .9,
  );
  canvas.drawRect(
    label.deflate(5),
    Paint()
      ..color = const Color(0xffc3a16a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .5,
  );
  for (var i = 0; i < 520; i++) {
    final point = Offset(
      label.left + random.nextDouble() * label.width,
      label.top + random.nextDouble() * label.height,
    );
    canvas.drawCircle(
      point,
      .35,
      Paint()..color = const Color(0xff332c24).withValues(alpha: .06),
    );
  }
}
