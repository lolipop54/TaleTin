import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';

/// 静止正文、原书平移和翻页截图共用尺寸与图标路径。
class SearchMenuAppearance {
  const SearchMenuAppearance(
    this.colors, {
    required this.previous,
    required this.next,
    required this.busy,
    this.returnProgress = false,
    this.activeButton,
  });
  final GtColors colors;
  final bool previous, next, busy;
  final bool returnProgress;
  final int? activeButton;
  // 按参考图的主体比例绘制；画布留白用于小圆叉与底部投影。
  static const width = 166.0, height = 66.0, bottom = 40.0;
  static const body = Rect.fromLTWH(6, 20, 154, 42);
  static const radius = 17.0, closeRadius = 7.0;
  static const centers = [
    Offset(34, 41),
    Offset(83, 41),
    Offset(134, 41),
    Offset(154, 23),
  ];
  static const labels = ['上一个搜索结果', '回到搜索前位置', '下一个搜索结果', '取消搜索导航'];
  double get menuWidth => returnProgress ? 142 : width;
  Rect get menuBody =>
      returnProgress ? const Rect.fromLTWH(6, 22, 130, 40) : body;
  double get bodyRadius => returnProgress ? 22 : radius;
  List<Offset> get iconCenters => returnProgress
      ? const [Offset.zero, Offset(30, 42), Offset.zero, Offset(128, 26)]
      : centers;
  List<int> get buttons => returnProgress ? const [1] : const [0, 1, 2];
  String label(int i) =>
      returnProgress ? (i == 1 ? '返回原进度' : '关闭返回提示') : labels[i];
  static const paths = <List<List<Offset>>>[
    [
      [Offset(9, 0), Offset(-9, 0)],
      [Offset(-2, -7), Offset(-9, 0), Offset(-2, 7)],
    ],
    [
      [Offset(-9, -4), Offset(3, -4)],
      [Offset(-2, -11), Offset(-9, -4), Offset(-2, 3)],
    ],
    [
      [Offset(-9, 0), Offset(9, 0)],
      [Offset(2, -7), Offset(9, 0), Offset(2, 7)],
    ],
    [
      [Offset(-3, -3), Offset(3, 3)],
      [Offset(3, -3), Offset(-3, 3)],
    ],
  ];
  bool enabled(int i) =>
      !busy &&
      (i == 0
          ? previous
          : i == 2
          ? next
          : true);
  Rect bounds(Size size) => Rect.fromLTWH(
    (size.width - menuWidth) / 2,
    size.height - bottom - height,
    menuWidth,
    height,
  );
  // 小圆叉仍有44dp热区，向上扩展并与主体热区分开。
  Rect button(int i) => i == 3
      ? Rect.fromLTWH(iconCenters[3].dx - 22, -13, 44, 44)
      : returnProgress
      ? const Rect.fromLTWH(6, 31, 130, 44)
      : Rect.fromLTWH(6 + i * (154 / 3), 31, 154 / 3, 44);

  Color get _closeColor =>
      Color.lerp(colors.textMuted, colors.borderSubtle, .65)!;
  Color _iconColor(int i) {
    if (i == 3) return _closeColor;
    final unavailable = (i == 0 && !previous) || (i == 2 && !next);
    final waiting = busy && i == (returnProgress ? 1 : activeButton);
    // 可点击状态仍统一防止重复操作，颜色只反映边界或本次点击。
    return unavailable || waiting
        ? Color.lerp(colors.textMuted, colors.surface, .65)!
        : colors.textMuted;
  }

  double _iconScale(int i) => returnProgress && i == 1 ? .72 : 1;

  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(bounds(size).left, bounds(size).top);
    final shape = Path()
      ..addRRect(
        RRect.fromRectAndRadius(menuBody, Radius.circular(bodyRadius)),
      );
    // 与进度条返回按钮的 Material elevation=2 使用相同阴影参数。
    for (final shadow in kElevationToShadow[2]!) {
      final rect = menuBody.shift(shadow.offset).inflate(shadow.spreadRadius);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(bodyRadius)),
        shadow.toPaint(),
      );
    }
    canvas.drawPath(shape, Paint()..color = colors.surface);
    final border = Paint()
      ..color = colors.borderSubtle
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final x in returnProgress ? <double>[] : [58.0, 108.0]) {
      canvas.drawLine(Offset(x, 28), Offset(x, 58), border);
    }
    if (returnProgress) {
      final text = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: label(1),
          style: TextStyle(
            color: _iconColor(1),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      )..layout();
      text.paint(canvas, Offset(47, 42 - text.height / 2));
      text.dispose();
    }
    if (returnProgress) {
      final icon = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: String.fromCharCode(Icons.undo.codePoint),
          style: TextStyle(
            fontFamily: Icons.undo.fontFamily,
            fontSize: 18,
            color: _iconColor(1),
          ),
        ),
      )..layout();
      icon.paint(canvas, Offset(21, 42 - icon.height / 2));
      icon.dispose();
    }
    for (final i in returnProgress ? <int>[] : buttons) {
      canvas.save();
      canvas.translate(iconCenters[i].dx, iconCenters[i].dy);
      canvas.scale(_iconScale(i));
      const center = Offset.zero;
      final pen = Paint()
        ..color = _iconColor(i)
        ..style = PaintingStyle.stroke
        ..strokeWidth = i == 3 ? 1.2 : 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final points in paths[i]) {
        final path = Path()
          ..moveTo(points.first.dx + center.dx, points.first.dy + center.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx + center.dx, point.dy + center.dy);
        }
        if (i == 1 && identical(points, paths[1].first)) {
          path.cubicTo(
            center.dx + 10,
            center.dy - 4,
            center.dx + 10,
            center.dy + 9,
            center.dx + 3,
            center.dy + 9,
          );
          path.lineTo(center.dx - 4, center.dy + 9);
        }
        canvas.drawPath(path, pen);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  /// 只含应用定义的路径及颜色；不会插入书籍文字或用户输入。
  String get svg {
    String color(Color c) =>
        '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    final shadows = kElevationToShadow[2]!;
    final out = StringBuffer(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$menuWidth" height="$height" viewBox="0 0 $menuWidth $height">',
    );
    for (var i = 0; i < shadows.length; i++) {
      final shadow = shadows[i];
      final rect = menuBody.shift(shadow.offset).inflate(shadow.spreadRadius);
      out.write(
        '<defs><filter id="shadow$i" x="-30%" y="-60%" width="160%" height="220%">'
        '<feGaussianBlur stdDeviation="${shadow.blurSigma}"/></filter></defs>'
        '<rect x="${rect.left}" y="${rect.top}" width="${rect.width}" height="${rect.height}" '
        'rx="$bodyRadius" fill="${color(shadow.color)}" fill-opacity="${shadow.color.a}" filter="url(#shadow$i)"/>',
      );
    }
    out.write(
      '<rect x="6" y="${menuBody.top}" width="${menuBody.width}" height="${menuBody.height}" '
      'rx="$bodyRadius" fill="${color(colors.surface)}"/>',
    );
    if (returnProgress) {
      out.write(
        '<text x="47" y="42" dominant-baseline="central" font-family="sans-serif" '
        'font-size="14" font-weight="500" fill="${color(_iconColor(1))}">${label(1)}</text>',
      );
    } else {
      out.write(
        '<path d="M58 28v30M108 28v30" stroke="${color(colors.borderSubtle)}"/>',
      );
    }
    if (returnProgress) {
      // Material Icons undo，18dp，与进度控制面板使用的图标相同。
      out.write(
        '<path transform="translate(21 33) scale(.75)" '
        'd="M12.5 8c-2.65 0-5.05.99-6.9 2.6L2 7v9h9l-3.62-3.62c1.39-1.16 3.16-1.88 5.12-1.88 '
        '3.54 0 6.55 2.31 7.6 5.5l2.37-.78C21.08 11.03 17.15 8 12.5 8z" fill="${color(_iconColor(1))}"/>',
      );
    }
    for (final i in returnProgress ? <int>[] : buttons) {
      out.write(
        '<g transform="translate(${iconCenters[i].dx} ${iconCenters[i].dy}) scale(${_iconScale(i)})">',
      );
      const center = Offset.zero;
      final tint = color(_iconColor(i));
      for (final points in paths[i]) {
        if (i == 1 && identical(points, paths[1].first)) {
          out.write(
            '<path d="M${center.dx - 9} ${center.dy - 4}h12'
            'C${center.dx + 10} ${center.dy - 4} ${center.dx + 10} ${center.dy + 9} '
            '${center.dx + 3} ${center.dy + 9}h-7" fill="none" '
            'stroke="$tint" stroke-width="1.5" stroke-linecap="round"/>',
          );
          continue;
        }
        out.write(
          '<polyline points="${points.map((p) => '${p.dx + center.dx},${p.dy + center.dy}').join(' ')}" '
          'fill="none" stroke="$tint" stroke-width="${i == 3 ? 1.2 : 1.5}" stroke-linecap="round" stroke-linejoin="round"/>',
        );
      }
      out.write('</g>');
    }
    return '$out</svg>';
  }
}
