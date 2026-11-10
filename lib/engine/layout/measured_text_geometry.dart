import 'package:flutter/painting.dart';

import 'math_formula.dart';
import 'background_image_style.dart';

/// 一行里的一段文字及其横向起点（行内有图片时，图片把文字隔成几段）。
class MeasuredSegment {
  const MeasuredSegment({
    required this.start,
    required this.end,
    required this.left,
    required this.width,
    this.letterSpacing = 0,
    this.top = 0,
    this.baseline = 0,
  });

  /// 在块文字里的范围 [start, end)
  final int start;
  final int end;

  /// 相对块内文字区左边缘的横坐标（像素）
  final double left;

  /// 这一段文字自身宽度（像素）
  final double width;
  final double letterSpacing;
  final double top, baseline;
}

/// 行内图片在一行里的摆放位置（尺寸已按阅读设置换算成像素）。
class InlineImagePlacement {
  const InlineImagePlacement({
    required this.offset,
    required this.line,
    required this.left,
    required this.top,
    required this.size,
    required this.resourcePath,
    this.alt,
    this.formula,
  });

  /// 在块文字里的字符位置（UTF-16）
  final int offset;

  /// 所在的测量行号
  final int line;

  /// 相对块内文字区左边缘的横坐标（像素）
  final double left;

  /// 相对本行上沿的纵坐标（像素）
  final double top;

  final Size size;
  final String resourcePath;
  final String? alt;
  final FormulaGeometry? formula;
}

/// 一行在块文本中的范围与高度。
class MeasuredLine {
  const MeasuredLine({
    required this.start,
    required this.end,
    required this.height,
    required this.width,
    this.hyphenated = false,
    this.hardBreak = false,
    this.left = 0,
    this.textTop = 0,
    this.segments = const [],
  });

  /// 行首偏移（UTF-16 code unit，相对整块文本）
  final int start;

  /// 行尾偏移；下一行的 start 就是本行的 end
  final int end;

  /// 行盒高度（像素）
  final double height;

  /// 这一行实际占用的宽度（像素，来自 `LineMetrics.width`）。
  ///
  /// 与内容宽度之差就是这一行的「空档」：多数行是「下一个字放不下」造成的
  /// 不到一个字的空档，标点避头尾时还会多出一个字的空档——绘制时按这个差值
  /// 拉开字距，行就能顶到右边（见 `createFragmentPainter` 的说明）。
  final double width;

  /// 显示层的英文断字连字符，不计入原文范围。
  final bool hyphenated;

  /// 这一行以硬换行（`<br>` 或代码换行）结束：不参与两端对齐。
  final bool hardBreak;

  /// 额外的左侧偏移（代码块行首缩进，像素）
  final double left;

  /// 行内有比文字高的图片时，文字在行里的向下偏移（让文字与图片垂直居中）。
  final double textTop;

  /// 行内图片把文字隔开的各段；为空表示这一行是普通文字行。
  final List<MeasuredSegment> segments;
}

/// 标题装饰块（章题）与其下短分隔线之间的间距
const double kTitleRuleGap = 12;
const double kTitleRuleThickness = 2;
const double kTitleRuleWidth = 36;

/// 分隔线块的固定高度（线居中）
const double kDividerHeight = 29;

/// 一个显示树容器在这一块上的像素盒子。外层先画，内层后画。
class ContainerBoxFrame {
  const ContainerBoxFrame({
    required this.elementId,
    required this.box,
    required this.first,
    required this.last,
    required this.left,
    required this.width,
    this.top = 0,
    this.height,
    this.bottom = 0,
    this.lineFrom = 0,
    this.lineTo,
  });

  final int elementId;
  final BlockBox box;

  /// 这个块是不是该容器的第一／最后一块；跨页片段还要结合行首尾。
  final bool first;
  final bool last;

  /// 盒子的左边缘与总宽度（内容坐标，已含本层及内层内边距／边框）。
  final double left;
  final double width;
  final double top;
  final double? height;

  /// 父层底部内边距不属于本层背景；分片只在真实末尾扣除。
  final double bottom;

  /// 块内容器只覆盖这些行，分页/滚动按同一范围裁剪。
  final int lineFrom;
  final int? lineTo;
}

/// 书内样式表给的盒子（背景、边框、圆角、阴影、内边距），单位已换算成像素。
class BlockBox {
  const BlockBox({
    required this.background,
    this.backgroundImage,
    required this.borderColors,
    required this.borderTop,
    required this.borderRight,
    required this.borderBottom,
    required this.borderLeft,
    this.borderStyles = const [1, 1, 1, 1],
    double radius = 0,
    BorderRadius? borderRadius,
    required this.shadows,
    required this.padTop,
    required this.padRight,
    required this.padBottom,
    required this.padLeft,
    // 保留公开的圆角参数名称，内部同时兼容旧的单半径构造。
    // ignore: prefer_initializing_formals
  }) : _borderRadius = borderRadius,
       // ignore: prefer_initializing_formals
       _radius = radius;

  /// 从正文/表格保存的原始盒子数组换成像素值。
  ///
  /// 数组口径与样式表一致：颜色、四边边框宽度、边框颜色、圆角、阴影、四边内边距，
  /// 单位都是 1/100 em；最后四位是四边线型（旧数组没有时按实线）。
  static BlockBox? fromRaw(List<int>? raw, double fontSize) {
    if (raw == null || raw.length < 18) return null;
    final em = fontSize / 100;
    double px(int value) => value * em;
    final radius = [px(raw[6]), px(raw[7]), px(raw[8]), px(raw[9])];
    final shadows = <BoxShadow>[];
    if (raw[10] != 0 || raw[11] != 0 || raw[12] != 0) {
      shadows.add(
        BoxShadow(
          offset: Offset(px(raw[10]), px(raw[11])),
          blurRadius: px(raw[12]),
          color: Color(raw[13]),
        ),
      );
    }
    // 旧数组只有一个边框颜色，四边都用它。
    return BlockBox(
      background: raw[0] == 0 ? null : Color(raw[0]),
      borderColors: List<Color>.filled(4, Color(raw[5])),
      borderStyles: raw.length < 22
          ? const [1, 1, 1, 1]
          : [raw[18], raw[19], raw[20], raw[21]],
      borderTop: px(raw[1]),
      borderRight: px(raw[2]),
      borderBottom: px(raw[3]),
      borderLeft: px(raw[4]),
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(radius[0]),
        topRight: Radius.circular(radius[1]),
        bottomRight: Radius.circular(radius[2]),
        bottomLeft: Radius.circular(radius[3]),
      ),
      shadows: shadows,
      padTop: px(raw[14]),
      padRight: px(raw[15]),
      padBottom: px(raw[16]),
      padLeft: px(raw[17]),
    );
  }

  /// 盒子是否什么都没画（避免无意义的绘制）
  final Color? background;
  final BookBackgroundImage? backgroundImage;

  /// 四条边各自的颜色（上、右、下、左）。
  ///
  /// 不能只存一个颜色：书里常见「上边浅灰、左边深色」这类写法，共用一个颜色
  /// 会让某一边按另一边的颜色画。没写颜色的边是透明，保持与当前行为一致。
  final List<Color> borderColors;

  /// 兼容旧代码／测试：返回第一条可见边的颜色。
  ///
  /// 绘制必须用 [borderColors]，不能用这个值，否则又退回「四边同色」。
  Color get borderColor => borderColors.firstWhere(
    (color) => color.toARGB32() != 0,
    orElse: () => const Color(0x00000000),
  );

  final double borderTop, borderRight, borderBottom, borderLeft;

  /// 上、右、下、左四边：1实线、2虚线、3圆点、4双线、5槽线、6脊线、7凹线、8凸线。
  final List<int> borderStyles;

  /// 四个角独立保留，不能取最大值后把直角也画圆。
  final BorderRadius? _borderRadius;
  final double _radius;
  BorderRadius get borderRadius =>
      _borderRadius ?? BorderRadius.circular(_radius);
  double get radius => _borderRadius == null
      ? _radius
      : [
          borderRadius.topLeft.x,
          borderRadius.topRight.x,
          borderRadius.bottomRight.x,
          borderRadius.bottomLeft.x,
        ].reduce((a, b) => a > b ? a : b);
  final List<BoxShadow> shadows;
  final double padTop, padRight, padBottom, padLeft;

  double get insetLeft => padLeft + borderLeft;
  double get insetRight => padRight + borderRight;
  double get insetTop => padTop + borderTop;
  double get insetBottom => padBottom + borderBottom;
}

/// 块内文字颜色与文字阴影（书内指定时使用，否则跟随阅读主题）。
class BlockTextStyle {
  const BlockTextStyle({this.color, this.shadows});

  final Color? color;
  final List<Shadow>? shadows;

  bool get isEmpty => color == null && (shadows == null || shadows!.isEmpty);

  BlockTextStyle merge(BlockTextStyle other) => BlockTextStyle(
    color: other.color ?? color,
    shadows: other.shadows ?? shadows,
  );
}
