import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../view_models/pdf_viewport.dart';
import 'search_menu_appearance.dart';

/// 第二指按下后，本轮剩下的一根手指也只平移。抬完再判定是否可以翻页。
class PdfZoomSurface extends StatefulWidget {
  const PdfZoomSurface({
    super.key,
    required this.view,
    required this.onBegin,
    required this.onZoom,
    this.fixedView = false,
    this.onEnd,
    this.onPanStart,
    this.onPan,
    this.onPanEnd,
    this.canStart,
    required this.child,
  });
  final PdfViewport view;
  final VoidCallback onBegin;
  final void Function(double scale, Offset from, Offset to, bool singleFinger)
  onZoom;
  final bool fixedView;
  final VoidCallback? onEnd;
  final VoidCallback? onPanStart;
  final void Function(Offset delta, Offset position)? onPan;
  final void Function(bool cancelled, bool startingZoom)? onPanEnd;
  final bool Function()? canStart;
  final Widget child;
  @override
  State<PdfZoomSurface> createState() => _PdfZoomSurfaceState();
}

class _PdfZoomSurfaceState extends State<PdfZoomSurface> {
  final _points = <int, Offset>{};
  Offset _focal = Offset.zero, _travel = Offset.zero;
  double _distance = 1, _startScale = 1, _scale = 1;
  bool _zooming = false, _panning = false, _panAllowed = false;

  (Offset, double) get _span {
    final first = _points.values.first;
    if (_points.length == 1) return (first, 0);
    final second = _points.values.elementAt(1);
    return ((first + second) / 2, (first - second).distance);
  }

  void _rebase() {
    final (focal, distance) = _span;
    _focal = focal;
    _distance = distance;
    _startScale = _scale;
    if (widget.fixedView) widget.view.rebaseFixedDrag();
  }

  void _down(PointerDownEvent e) {
    if (_points.isEmpty) {
      if (widget.view.busy || !(widget.canStart?.call() ?? true)) return;
      _panAllowed = !widget.fixedView && widget.view.scale > 1;
      _travel = Offset.zero;
      _scale = widget.view.scale;
    }
    _points[e.pointer] = e.localPosition;
    if (!_zooming && (_points.length >= 2 || widget.view.editing)) {
      if (_panning) widget.onPanEnd?.call(true, true);
      _panning = false;
      _zooming = true;
      widget.view.begin(fixedView: widget.fixedView);
      widget.onBegin();
    }
    _rebase();
  }

  void _move(PointerMoveEvent e) {
    if (!_points.containsKey(e.pointer)) return;
    final delta = e.localPosition - _points[e.pointer]!;
    _points[e.pointer] = e.localPosition;
    if (_zooming) {
      final (focal, distance) = _span;
      if (_distance < 1 && distance >= 1) _rebase();
      if (_points.length >= 2 && _distance >= 1) {
        _scale = (_startScale * distance / _distance).clamp(
          PdfViewport.minScale,
          PdfViewport.maxScale,
        );
      }
      widget.onZoom(_scale, _focal, focal, _points.length == 1);
      _focal = focal;
    } else if (_panAllowed) {
      if (_panning) {
        widget.onPan?.call(delta, e.localPosition);
      } else {
        _travel += delta;
        if (_travel.distance >= kPanSlop / 2) {
          _panning = true;
          widget.onPanStart?.call();
          widget.onPan?.call(_travel, e.localPosition);
        }
      }
    }
  }

  void _up(PointerEvent e) {
    if (_points.remove(e.pointer) == null) return;
    if (_points.isEmpty) {
      if (_zooming) {
        _zooming = false;
        widget.view.end();
        widget.onEnd?.call();
      } else if (_panning) {
        _panning = false;
        widget.onPanEnd?.call(e is PointerCancelEvent, false);
      }
    } else {
      _rebase();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _up,
    child: IgnorePointer(ignoring: !widget.view.canTurn, child: widget.child),
  );
}

/// 复用返回原进度面板的底部位置，确认之后才恢复正文手势。
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
    onPressed: view.touching || view.busy ? null : () => onConfirm(reset),
    child: Builder(
      builder: (context) {
        final pressed = FButtonData.of(context).variants
            .contains(FTappableVariant.pressed);
        // 面板底色保持不变，只把文字变浅，按住时也不缩放或移动。
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 42),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
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
        padding: const EdgeInsets.fromLTRB(
          8,
          0,
          8,
          SearchMenuAppearance.bottom + 4,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(SearchMenuAppearance.radius),
            boxShadow: kElevationToShadow[2],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: _button(
                  'pdf-fix-view',
                  '固定视图 ${(view.scale * 100).round()}%',
                  false,
                ),
              ),
              Container(width: 1, height: 30, color: colors.borderSubtle),
              Flexible(child: _button('pdf-reset-view', '重置视图', true)),
            ],
          ),
        ),
      ),
    ),
  );
}
