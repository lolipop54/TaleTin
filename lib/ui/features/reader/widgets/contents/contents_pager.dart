import 'package:flutter/material.dart';

/// 跟阅读平移翻页相同：起手固定方向，1/4 宽度或 420px/s 提交，220ms 收尾。
class ContentsPager extends StatefulWidget {
  /// 点击页签与手势松手共用横滑收尾；保持现有手势阈值和时长。
  static void select(GlobalKey key, int index) {
    final state = key.currentState;
    if (state is _ContentsPagerState) state._select(index);
  }
  const ContentsPager({
    super.key,
    required this.index,
    required this.onChanged,
    required this.children,
    this.onPositionChanged,
  });
  final int index;
  final ValueChanged<int> onChanged;
  final List<Widget> children;

  /// 含拖动和回弹的连续页位置，供页签指示线与正文同步移动。
  final ValueChanged<double>? onPositionChanged;
  @override
  State<ContentsPager> createState() => _ContentsPagerState();
}

class _ContentsPagerState extends State<ContentsPager>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<double>? _tween;
  double _shift = 0, _width = 0;
  int _direction = 0;
  bool _settling = false, _dragging = false;

  void _select(int index) {
    if (_settling || _dragging || index == widget.index || _width == 0) return;
    _direction = index - widget.index;
    _finish(true);
  }

  @override
  void initState() {
    super.initState();
    _animation.addListener(() {
      setState(() => _shift = _tween!.value);
      _publishPosition();
    });
  }

  @override
  void didUpdateWidget(ContentsPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      _animation.stop();
      _shift = 0;
      _dragging = _settling = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _publishPosition();
      });
    }
  }

  void _publishPosition() => widget.onPositionChanged?.call(
    widget.index - (_width == 0 ? 0 : _shift / _width),
  );

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  Future<void> _finish(bool commit) async {
    _dragging = false;
    setState(() => _settling = true);
    final target = commit ? -_direction * _width : 0.0;
    if (!MediaQuery.disableAnimationsOf(context)) {
      _tween = Tween<double>(
        begin: _shift,
        end: target,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_animation);
      try {
        await _animation.forward(from: 0).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    final next = widget.index + (commit ? _direction : 0);
    // 新视图和零位移同帧更新，不在收尾后闪回旧视图。
    setState(() {
      _shift = 0;
      _settling = false;
      _direction = 0;
    });
    if (next != widget.index) widget.onChanged(next);
    widget.onPositionChanged?.call(next.toDouble());
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) {
      _width = constraints.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          if (_settling) return;
          _dragging = true;
          _direction = 0;
        },
        onHorizontalDragUpdate: (details) {
          if (!_dragging) return;
          final dx = details.delta.dx;
          if (_direction == 0 && dx != 0) _direction = dx < 0 ? 1 : -1;
          if (widget.index + _direction < 0 ||
              widget.index + _direction >= widget.children.length) {
            return;
          }
          setState(
            () => _shift = (_shift + dx).clamp(
              _direction == 1 ? -_width : 0.0,
              _direction == -1 ? _width : 0.0,
            ),
          );
          _publishPosition();
        },
        onHorizontalDragEnd: (details) {
          if (!_dragging) return;
          final velocity = details.velocity.pixelsPerSecond.dx;
          final valid =
              widget.index + _direction >= 0 &&
              widget.index + _direction < widget.children.length;
          _finish(
            valid &&
                _direction != 0 &&
                (_shift.abs() > _width * .25 ||
                    (_direction == 1 ? velocity < -420 : velocity > 420)),
          );
        },
        onHorizontalDragCancel: () {
          if (_dragging) _finish(false);
        },
        child: ClipRect(
          child: Stack(
            children: [
              for (var i = 0; i < widget.children.length; i++)
                Positioned.fill(
                  child: Offstage(
                    offstage: (i - widget.index).abs() > 1 &&
                        !(_settling && i == widget.index + _direction),
                    child: Transform.translate(
                      offset: Offset((i - widget.index) * _width + _shift, 0),
                      child: ExcludeSemantics(
                        excluding: i != widget.index,
                        child: ExcludeFocus(
                          excluding: i != widget.index,
                          child: IgnorePointer(
                            ignoring: i != widget.index || _settling,
                            child: RepaintBoundary(child: widget.children[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
