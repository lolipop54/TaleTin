import 'package:flutter/material.dart';

/// 参考图里的“纸张折角 / 蓝色书签带”装饰。
/// 仅用于书架、成就、设置、导入等页面；阅读页及其子面板禁止使用折角
/// （设计文档 9.1：避免与仿真翻页的页面边角冲突）。

/// 纸角折起装饰（参考图里的蓝色小折角）：
/// 上端收尖，蓝色折面向右下展开，下面露出白色纸面与轻微投影。
/// 高度由 [height] 控制，宽度为高度的 0.60。
class FoldCorner extends StatelessWidget {
  const FoldCorner({
    super.key,
    this.height = 16,
    this.color = const Color(0xFF2468C9),
  });

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * 0.60,
      height: height,
      child: CustomPaint(painter: _SmallFoldPainter(color)),
    );
  }
}

class _SmallFoldPainter extends CustomPainter {
  const _SmallFoldPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 白纸底面略向左展开，底边近水平；不能画成右侧垂直的旗帜。
    final paper = Path()
      ..moveTo(w * 0.24, h * 0.02)
      ..lineTo(w * 0.05, h * 0.92)
      ..quadraticBezierTo(w * 0.48, h * 0.91, w * 0.96, h * 0.95)
      ..close();
    canvas.drawPath(
      paper.shift(Offset(0, h * 0.035)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.055),
    );
    canvas.drawPath(paper, Paint()..color = const Color(0xFFFCFBF8));
    // 折痕位于左下，蓝面从同一个上端尖点向右下尖点展开。
    final fold = Path()
      ..moveTo(w * 0.24, h * 0.02)
      ..quadraticBezierTo(w * 0.63, h * 0.53, w * 0.96, h * 0.95)
      ..lineTo(w * 0.29, h * 0.68)
      ..close();
    canvas.drawPath(
      fold,
      Paint()..shader = LinearGradient(
        colors: [Color.lerp(color, Colors.white, 0.16)!, color],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_SmallFoldPainter oldDelegate) => oldDelegate.color != color;
}

/// 卡片右上角的折角：等比放大设置页的蓝白纸张折角，
/// 贴在卡片右上角的外侧（参考图 04 / 06 的卡片）。
class CardFoldCorner extends StatelessWidget {
  const CardFoldCorner({
    super.key,
    this.height = 48,
    this.color = const Color(0xFF2468C9),
  });

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      FoldCorner(height: height, color: color);
}

/// 顶部垂下的书签带（导入页右上角）：底边带三角缺口。
class RibbonBookmark extends StatelessWidget {
  const RibbonBookmark({
    super.key,
    this.width = 26,
    this.height = 52,
    this.color = const Color(0xFF2468C9),
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _RibbonPainter(color)),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final notch = w * 0.32; // 底部缺口深度
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(w, h)
        ..lineTo(w / 2, h - notch)
        ..lineTo(0, h)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_RibbonPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 书架封面标签：像夹在书里的书签，只有上半截露在封面之上。
/// 圆角矩形（上方两角圆、底边被封面盖住），参考图里没有缺口。
class CoverFlag extends StatelessWidget {
  const CoverFlag({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  /// 标签尺寸：最小宽 34 / 高 19，底沿与封面顶边相接，不侵入封面。
  /// 文字更长时（如「12.34%」）宽度按内容撑开，高度不变。
  static const double flagWidth = 34;
  static const double flagHeight = 19;

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: flagWidth, minHeight: flagHeight),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(4),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
        // 字号比正文小一号，四周留白看起来更像夹在书里的书签
        style: TextStyle(
          fontSize: 9,
          height: 1.0,
          color: foreground,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 竖排文字（占位封面左侧的书名落款）。
/// 中文逐字竖排，标点不做特殊处理（样例文案无标点换行问题）。
class VerticalText extends StatelessWidget {
  const VerticalText(
    this.text, {
    super.key,
    required this.style,
    this.spacing = 0,
  });

  final String text;
  final TextStyle style;
  /// 字与字之间的额外间距
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final chars = text.characters.toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chars.length; i++) ...[
          Text(chars[i], style: style),
          if (i != chars.length - 1 && spacing > 0) SizedBox(height: spacing),
        ],
      ],
    );
  }
}
