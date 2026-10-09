import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'reader_gallery_frame.dart';
import 'reader_image_viewport.dart';

/// 与正文平移翻页相同：1/4屏宽或420px/s提交，220ms平移收尾。
/// 只预备前后各一张，邻图未解码时保留当前画面。
class ReaderGalleryPager extends StatefulWidget {
  const ReaderGalleryPager({
    super.key,
    required this.first,
    required this.initialIndex,
    required this.count,
    required this.load,
    required this.onChanged,
    required this.onBusy,
    required this.onError,
    required this.onBlankTap,
  });
  final ReaderGalleryFrame first;
  final int initialIndex, count;
  final Future<ReaderGalleryFrame> Function(int, BuildContext) load;
  final ValueChanged<int> onChanged;
  final ValueChanged<bool> onBusy;
  final VoidCallback onError;
  final VoidCallback onBlankTap;
  @override
  State<ReaderGalleryPager> createState() => _ReaderGalleryPagerState();
}

class _ReaderGalleryPagerState extends State<ReaderGalleryPager>
    with SingleTickerProviderStateMixin {
  late int _index = widget.initialIndex;
  late final _frames = <int, ReaderGalleryFrame>{_index: widget.first};
  final _pending = <int, Future<ReaderGalleryFrame?>>{};
  final _transform = TransformationController();
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  final _pointers = <int>{};
  VelocityTracker? _velocity;
  Offset? _start;
  double _offset = 0, _dragged = 0, _width = 1;
  bool _multiple = false, _settling = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prefetch();
  }

  void _prefetch() {
    _load(_index - 1);
    _load(_index + 1);
  }

  Future<ReaderGalleryFrame?> _load(int index) {
    if (index < 0 || index >= widget.count) return Future.value();
    if (_frames[index] case final ready?) return Future.value(ready);
    return _pending.putIfAbsent(index, () async {
      try {
        final frame = await widget.load(index, context);
        if (!mounted) {
          frame.dispose();
          return null;
        }
        if ((index - _index).abs() > 1) {
          frame.dispose();
          return null;
        }
        setState(() {
          _frames[index] = frame;
          if (_start != null &&
              !_multiple &&
              _transform.value.getMaxScaleOnAxis() <= 1.01) {
            _updateOffset();
          }
        });
        return frame;
      } catch (_) {
        return null;
      } finally {
        _pending.remove(index);
      }
    });
  }

  void _updateOffset() {
    final target = _index + (_dragged < 0 ? 1 : -1);
    _offset = _frames.containsKey(target) ? _dragged.clamp(-_width, _width) : 0;
  }

  Future<void> _animate(double target) async {
    final from = _offset;
    void tick() {
      if (mounted) {
        setState(
          () => _offset =
              from +
              (target - from) * Curves.easeOutCubic.transform(_animation.value),
        );
      }
    }

    _animation.addListener(tick);
    try {
      await _animation.forward(from: 0).orCancel;
    } on TickerCanceled {
      /* 窗口退出会终止动画。 */
    } finally {
      _animation.removeListener(tick);
    }
  }

  Future<void> _finish({bool cancelled = false}) async {
    if (_settling) return;
    // 单击或只缩放时没有翻图位移，不启动220ms回弹，也不阻止空白点击关闭。
    if (_dragged == 0 && _offset == 0) {
      _start = null;
      return;
    }
    _settling = true;
    widget.onBusy(true);
    final delta = _dragged,
        velocity = _velocity?.getVelocity().pixelsPerSecond.dx ?? 0;
    final direction = delta < 0 ? 1 : -1;
    final target = _index + direction;
    _start = null;
    final commit =
        !cancelled &&
        target >= 0 &&
        target < widget.count &&
        (delta.abs() > _width * .25 ||
            (delta.abs() > kTouchSlop && velocity * direction < -420));
    try {
      final next = commit ? await _load(target) : null;
      if (!mounted) return;
      if (commit && next == null) widget.onError();
      await _animate(next == null ? 0 : -direction * _width);
      if (!mounted) return;
      if (next != null) {
        setState(() {
          _index = target;
          _offset = 0;
          _transform.value = Matrix4.identity();
        });
        widget.onChanged(_index);
        final stale = _frames.keys
            .where((i) => (i - _index).abs() > 1)
            .toList();
        for (final key in stale) {
          final frame = _frames.remove(key)!;
          WidgetsBinding.instance.addPostFrameCallback((_) => frame.dispose());
        }
        _prefetch();
      }
    } finally {
      _settling = false;
      _dragged = 0;
      if (mounted) widget.onBusy(false);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _transform.dispose();
    for (final frame in _frames.values) {
      frame.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth;
      return ClipRect(
        child: Listener(
          onPointerDown: (event) {
            _pointers.add(event.pointer);
            if (_settling) return;
            if (_pointers.length == 1) {
              _start = event.position;
              _dragged = 0;
              _multiple = false;
              _velocity = VelocityTracker.withKind(event.kind)
                ..addPosition(event.timeStamp, event.position);
            } else {
              _multiple = true;
              if (_offset != 0) _finish(cancelled: true);
            }
          },
          onPointerMove: (event) {
            if (_settling ||
                _multiple ||
                _start == null ||
                _transform.value.getMaxScaleOnAxis() > 1.01) {
              return;
            }
            _velocity?.addPosition(event.timeStamp, event.position);
            final delta = event.position - _start!;
            if (delta.dx.abs() < kTouchSlop ||
                delta.dx.abs() <= delta.dy.abs() * 1.2) {
              return;
            }
            setState(() {
              _dragged = delta.dx;
              _updateOffset();
            });
          },
          onPointerUp: (event) {
            _pointers.remove(event.pointer);
            if (_settling || _start == null) return;
            _velocity?.addPosition(event.timeStamp, event.position);
            _finish(
              cancelled:
                  _multiple || _transform.value.getMaxScaleOnAxis() > 1.01,
            );
          },
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            _finish(cancelled: true);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_offset != 0)
                if (_frames[_index + (_offset < 0 ? 1 : -1)]
                    case final adjacent?)
                  Transform.translate(
                    offset: Offset(
                      _offset + (_offset < 0 ? _width : -_width),
                      0,
                    ),
                    child: SizedBox.expand(child: adjacent.widget),
                  ),
              Transform.translate(
                offset: Offset(_offset, 0),
                child: ReaderImageViewport(
                  transform: _transform,
                  imageSize: _frames[_index]!.imageSize,
                  onBlankTap: widget.onBlankTap,
                  child: _frames[_index]!.widget,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
