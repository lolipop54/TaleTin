import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../view_models/pdf_viewport.dart';
import 'search_menu_appearance.dart';

/// 原始触点负责双指缩放，单指仍交给既有五种翻页。
/// 第二指按下立即停翻页；本轮剩余单指只拖动，抬起后才重新判定下一轮手势。
class PdfZoomSurface extends StatefulWidget {
  const PdfZoomSurface({
    super.key,
    required this.view,
    required this.onBegin,
    this.onEnd,
    required this.child,
  });
  final PdfViewport view;
  final VoidCallback onBegin;
  final VoidCallback? onEnd;
  final Widget child;
  @override
  State<PdfZoomSurface> createState() => _PdfZoomSurfaceState();
}

class _PdfZoomSurfaceState extends State<PdfZoomSurface> {
  final _points = <int, Offset>{};
  Offset _center = Offset.zero,
      _startOffset = Offset.zero,
      _focal = Offset.zero;
  double _distance = 1, _startScale = 1;
  bool _active = false;
  bool _snappedX = false, _snappedY = false;

  void _rebase() {
    final points = _points.values.take(2).toList();
    if (points.isEmpty) return;
    _focal = points.length == 1 ? points.first : (points[0] + points[1]) / 2;
    _distance = points.length == 1 ? 1 : (points[0] - points[1]).distance;
    _startOffset = widget.view.offset;
    _startScale = widget.view.scale;
    _snappedX = _startOffset.dx.abs() < 1;
    _snappedY = _startOffset.dy.abs() < 1;
  }

  void _down(PointerDownEvent e) {
    if (widget.view.busy) return;
    _points[e.pointer] = e.localPosition;
    if (!_active && (_points.length >= 2 || widget.view.editing)) {
      _active = true;
      widget.view.begin();
      widget.onBegin();
    }
    _rebase();
  }

  void _move(PointerMoveEvent e) {
    if (!_points.containsKey(e.pointer)) return;
    _points[e.pointer] = e.localPosition;
    if (!_active) return;
    final points = _points.values.take(2).toList();
    final focal = points.length == 1 ? points[0] : (points[0] + points[1]) / 2;
    final scale = points.length < 2 || _distance < 1
        ? _startScale
        : (_startScale * (points[0] - points[1]).distance / _distance).clamp(
            .5,
            2.0,
          );
    // 固定两指中点下的内容，既能缩放也能同时平移。
    final ratio = scale / _startScale;
    var offset = focal - _center - (_focal - _center - _startOffset) * ratio;
    if (points.length == 1) {
      // 靠近中心12dp时吸附；已吸附后拖出22dp再离开，避免边界来回抖动。
      _snappedX = offset.dx.abs() <= (_snappedX ? 22 : 12);
      _snappedY = offset.dy.abs() <= (_snappedY ? 22 : 12);
      offset = Offset(_snappedX ? 0 : offset.dx, _snappedY ? 0 : offset.dy);
    }
    final size = context.size!;
    // 允许查看页边，又不会把整张页面拖出窗口后找不回来。
    widget.view.update(
      scale,
      Offset(
        offset.dx.clamp(-size.width * scale / 2, size.width * scale / 2),
        offset.dy.clamp(-size.height * scale / 2, size.height * scale / 2),
      ),
    );
  }

  void _up(PointerEvent e) {
    _points.remove(e.pointer);
    if (_points.isEmpty) {
      if (_active) {
        widget.view.end();
        widget.onEnd?.call();
      }
      _active = false;
    } else {
      _rebase();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) {
      _center = constraints.biggest.center(Offset.zero);
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: ListenableBuilder(
          listenable: widget.view,
          builder: (_, child) =>
              IgnorePointer(ignoring: !widget.view.canTurn, child: child),
          child: widget.child,
        ),
      );
    },
  );
}

/// 沿用搜索跳转面板的底部位置、圆角、投影和分隔线，换成两个文字按钮。
class PdfZoomMenu extends StatelessWidget {
  const PdfZoomMenu({
    super.key,
    required this.view,
    required this.colors,
    required this.onConfirm,
  });
  final PdfViewport view;
  final GtColors colors;
  final void Function(bool reset) onConfirm;
  Widget _button(String key, String label, bool reset) => GtButton.raw(
    key: Key(key),
    borderRadius: BorderRadius.circular(SearchMenuAppearance.radius),
    onPressed: view.busy || view.touching ? null : () => onConfirm(reset),
    child: Builder(
      builder: (context) {
        final pressed = FButtonData.of(context).variants
            .contains(FTappableVariant.pressed);
        // 面板底色保持不变，只把文字变浅，按住时也不缩放或移动。
        return SizedBox(
          height: 42,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: pressed
                      ? colors.textMuted.withValues(alpha: .5)
                      : colors.textMuted,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
  @override
  Widget build(BuildContext context) => SafeArea(
    maintainBottomViewPadding: true,
    child: Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: SearchMenuAppearance.bottom + 4),
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(SearchMenuAppearance.radius),
            boxShadow: kElevationToShadow[2],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _button(
                'pdf-fix-view',
                '固定视图 ${(view.scale * 100).round()}%',
                false,
              ),
              Container(width: 1, height: 30, color: colors.borderSubtle),
              _button('pdf-reset-view', '重置视图', true),
            ],
          ),
        ),
      ),
    ),
  );
}
