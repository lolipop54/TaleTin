import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:taletin/platform/channels/system_toast.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';

/// 数值始终显示在滑块内；保存期间保持拖动预览，避免先跳回旧值。
enum SliderLabelPosition { above, left }

class SettingsSlider extends StatefulWidget {
  const SettingsSlider({
    super.key,
    required this.label,
    this.labelPosition = SliderLabelPosition.left,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.save,
    this.leading,
    this.trailing,
    this.compact = false,
    this.backgroundColor,
    this.showNumber = true,
    this.onPreview,
    this.thumbRadius,
    this.trackThickness,
    this.progressColor,
    this.showProgress = true,
    this.labelStyle,
    this.numberStyle,
    this.disableWhileSaving = true,
  });
  final String label;
  final SliderLabelPosition labelPosition;
  final double value, min, max;
  final int divisions;
  final String Function(double) format;
  final Future<void> Function(double)? save;
  final Widget? leading, trailing;

  /// 阅读面板使用细轨道，颜色由面板纸张底色调和。
  final bool compact;
  final Color? backgroundColor;
  final bool showNumber;

  /// 拖动中的即时效果；松手仍只保存一次，完成后撤销临时值。
  final ValueChanged<double?>? onPreview;

  /// 圆形拖动块的半径；不传就按里面数字的大小自动算（面板 13~32、设置页 18~32）。
  /// 数字必须装得进圆里，所以传得比数字需要的半径还小时会被抬上去。
  final double? thumbRadius;

  /// 拖动条（圆角长条）的粗细；不传就按拇指半径推：面板 1.5 倍、设置页 2 倍。
  final double? trackThickness;

  /// 圆块左侧「已经拖到哪」这一段的颜色；不传就按轨道色往文字色再调深一档。
  final Color? progressColor;

  /// 是否画圆块左侧的进度段（默认画）。设置页那种整条平色的浅灰轨道可以关掉。
  final bool showProgress;

  final TextStyle? labelStyle;
  final TextStyle? numberStyle;

  /// 阅读进度允许新拖动接管尚未完成的跳转；普通设置保存时仍禁用重复输入。
  final bool disableWhileSaving;

  @override
  State<SettingsSlider> createState() => _SettingsSliderState();
}

class _SettingsSliderState extends State<SettingsSlider>
    with SingleTickerProviderStateMixin {
  double? _preview;
  bool _saving = false;
  bool _dragging = false;
  Offset? _pointerDown;
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: widget.value,
  )..addListener(() => setState(() {}));
  Future<void> _settling = Future.value();
  int _request = 0;

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _change(double value) {
    _request++;
    if (_preview == null) _position.value = widget.value;
    setState(() => _preview = value);
    // 进度段和圆块读取同一逐帧值，避免一个已到触点、另一个还在路上。
    if (_dragging || MediaQuery.disableAnimationsOf(context)) {
      _position.value = value;
    } else {
      _settling = _animateTo(value);
    }
    widget.onPreview?.call(value);
  }

  Future<void> _animateTo(double value) async {
    try {
      await _position
          .animateTo(
            value,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
    } on TickerCanceled {
      // 拖动会接管点击动画；页面关闭时也不再等待旧动画。
    }
  }

  Future<void> _save(double value) async {
    final request = ++_request;
    final step = (widget.max - widget.min) / widget.divisions;
    value = (widget.min + ((value - widget.min) / step).round() * step).clamp(
      widget.min,
      widget.max,
    );
    setState(() {
      _saving = true;
      _preview = value;
    });
    if (_dragging ||
        MediaQuery.disableAnimationsOf(context) ||
        !_position.isAnimating) {
      _position.value = value;
    } else {
      _settling = _animateTo(value);
    }
    try {
      await widget.save!(value);
    } catch (_) {
      if (mounted && request == _request) {
        SystemToast.show('设置未保存，请重试').ignore();
      }
    } finally {
      // 保存可能立即完成，仍等这一次点击运动完成才撤销预览。
      await _settling;
      if (mounted && request == _request) {
        widget.onPreview?.call(null);
        setState(() {
          _saving = false;
          _preview = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gtColors;
    final value = (_preview == null ? widget.value : _position.value).clamp(
      widget.min,
      widget.max,
    );
    final enabled =
        widget.save != null && !(_saving && widget.disableWhileSaving);
    final background = widget.backgroundColor;
    final trackColor = background == null
        ? c.subtle
        : Color.lerp(background, c.textPrimary, .06)!;
    final thumbColor = background == null
        ? c.surface
        : Color.lerp(background, c.surface, .45)!;
    // 圆块左侧「已经拖到哪」这一段：同一条调和公式，比轨道再深一档。
    final progressColor =
        widget.progressColor ?? Color.lerp(trackColor, c.textPrimary, .16)!;
    final numberStyle =
        widget.numberStyle ??
        TextStyle(
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          fontSize: widget.compact ? 10 : 13,
          fontWeight: widget.compact ? FontWeight.w500 : FontWeight.bold,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: widget.save == null ? c.textMuted : c.textPrimary,
        );
    TextPainter measure(double v) => TextPainter(
      text: TextSpan(
        text: widget.showNumber ? widget.format(v) : '',
        style: numberStyle,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final number = measure(value);
    final lower = measure(widget.min), upper = measure(widget.max);
    // 尺寸只由范围和系统字号决定，拖动时数字变化不能带动下方设置移动。
    final textRadius =
        math.max(
          math.max(lower.width, upper.width),
          math.max(lower.height, upper.height),
        ) /
        2;
    final radius = math.max(
      widget.thumbRadius ??
          (textRadius + (widget.compact ? 2 : 8)).clamp(
            widget.compact ? 13.0 : 18.0,
            32.0,
          ),
      // 数字要装得进圆里：传了更小的半径时按数字需要的最小值走。
      textRadius + 1,
    );
    lower.dispose();
    upper.dispose();
    final trackHeight =
        widget.trackThickness ?? (widget.compact ? radius * 1.5 : radius * 2);
    final height = math.max(36.0, radius * 2 + 8);
    final slider = SizedBox(
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 轨道 + 圆块左侧的进度段。进度段画在两端图标下面、圆块下面：
          // 圆块在最上层（它要能盖住两端的图标），所以不能借 Slider 自己的
          // activeTrack 来画，否则进度色会连着图标一起涂掉。
          // 宽度按圆块中心算，右端正好被圆块盖住，不用留缝。
          LayoutBuilder(
            builder: (context, constraints) {
              final travel = math.max(0.0, constraints.maxWidth - radius * 2);
              final fraction = widget.max > widget.min
                  ? ((value - widget.min) / (widget.max - widget.min)).clamp(
                      0.0,
                      1.0,
                    )
                  : 0.0;
              return Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    height: trackHeight,
                    decoration: BoxDecoration(
                      color: trackColor,
                      borderRadius: BorderRadius.circular(trackHeight / 2),
                    ),
                  ),
                  if (widget.showProgress)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        key: const ValueKey('slider-progress'),
                        width: radius + travel * fraction,
                        height: trackHeight,
                        decoration: BoxDecoration(
                          color: progressColor,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(trackHeight / 2),
                            bottomLeft: Radius.circular(trackHeight / 2),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (widget.leading != null || widget.trailing != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [?widget.leading, const Spacer(), ?widget.trailing],
              ),
            ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 0,
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              disabledActiveTrackColor: Colors.transparent,
              disabledInactiveTrackColor: Colors.transparent,
              thumbColor: thumbColor,
              disabledThumbColor: thumbColor,
              overlayShape: SliderComponentShape.noOverlay,
              tickMarkShape: SliderTickMarkShape.noTickMark,
              showValueIndicator: ShowValueIndicator.never,
              thumbShape: _NumberThumb(
                number,
                radius,
                thumbColor,
                c.scrim.withValues(alpha: widget.compact ? .1 : .4),
              ),
            ),
            child: Semantics(
              label: widget.label,
              child: Listener(
                onPointerDown: (event) {
                  _dragging = false;
                  _pointerDown = event.localPosition;
                },
                onPointerMove: (event) {
                  if (_pointerDown != null &&
                      (event.localPosition - _pointerDown!).distance > 2) {
                    _dragging = true;
                  }
                },
                child: Slider(
                  // 手柄可以覆盖两侧标识，边缘对应真正的最小/最大值。
                  padding: EdgeInsets.symmetric(horizontal: radius),
                  value: value,
                  min: widget.min,
                  max: widget.max,
                  // 不让 Slider 再做独立位移动画；离散步长只在松手保存时处理。
                  divisions: null,
                  semanticFormatterCallback: widget.format,
                  onChanged: enabled ? _change : null,
                  onChangeEnd: enabled ? _save : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (widget.label.isEmpty) return slider;
    final label = Text(
      widget.label,
      style: widget.labelStyle ?? GtText.body(c.textPrimary),
    );
    return widget.labelPosition == SliderLabelPosition.above
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [label, const SizedBox(height: 8), slider],
          )
        : Row(
            children: [
              SizedBox(
                width:
                    MediaQuery.textScalerOf(context).scale(14).clamp(14, 22) *
                        4 +
                    12,
                child: label,
              ),
              Expanded(child: slider),
            ],
          );
  }
}

class _NumberThumb extends SliderComponentShape {
  const _NumberThumb(this.number, this.radius, this.color, this.shadow);
  final TextPainter number;
  final double radius;
  final Color color, shadow;
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(radius);
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawShadow(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
      shadow,
      1.5,
      false,
    );
    canvas.drawCircle(center, radius, Paint()..color = color);
    number.paint(canvas, center - Offset(number.width / 2, number.height / 2));
  }
}
