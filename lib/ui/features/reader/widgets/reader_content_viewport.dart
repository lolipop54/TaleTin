import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/diagnostics/reader_recovery_diagnostics.dart';

/// 输入框从获得焦点到键盘收起期间，正文沿用原来的窗口尺寸与安全区。
/// 面板是此组件的兄弟节点，仍能使用实时键盘高度向上让位。
class ReaderContentViewport extends StatefulWidget {
  const ReaderContentViewport({
    super.key,
    required this.child,
    this.settleWindowResize = false,
  });

  final Widget child;
  final bool settleWindowResize;

  @override
  State<ReaderContentViewport> createState() => _ReaderContentViewportState();
}

class _ReaderContentViewportState extends State<ReaderContentViewport> {
  MediaQueryData? _media;
  Size? _size;
  Size? _pendingSize;
  Timer? _resize;
  bool _editing = false;
  Object? _diagnosticGeometry;

  @override
  void initState() {
    super.initState();
    _editing = _hasEditableFocus;
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _resize?.cancel();
    FocusManager.instance.removeListener(_focusChanged);
    super.dispose();
  }

  bool get _hasEditableFocus =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  void _focusChanged() {
    final editing = _hasEditableFocus;
    if (_editing != editing) setState(() => _editing = editing);
  }

  void _cancelResize() {
    _resize?.cancel();
    _resize = null;
    _pendingSize = null;
  }

  // 拖动窗口时继续显示最近一次可读的纸面。宽度和高度一起交接，
  // 避免中间尺寸反复切换单双页、重排当前章及更换全书计数进程。
  void _acceptSize(Size size, MediaQueryData media) {
    if (!widget.settleWindowResize || _size == null || size == _size) {
      _cancelResize();
      _size = size;
      _media = media;
    } else if (_pendingSize != size) {
      _cancelResize();
      _pendingSize = size;
      _resize = Timer(const Duration(milliseconds: 180), () {
        setState(() {
          _size = size;
          _pendingSize = null;
          _resize = null;
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 系统栏可以先于键盘高度变化，因此获得输入焦点时就停止更新正文几何。
        // 旋转、分屏等真实窗口尺寸变化仍正常交给正文重新布局。
        final holding = _editing || media.viewInsets.bottom > 0;
        final sizeNow = constraints.biggest;
        if (widget.settleWindowResize &&
            (sizeNow.isEmpty || media.size.isEmpty)) {
          // 最小化时没有可供分页的纸面，恢复到原尺寸即可沿用原计数。
          _cancelResize();
          if (_size == null) return const SizedBox.shrink();
        } else if (_media == null ||
            !holding ||
            _media!.size != media.size ||
            _size!.width != constraints.maxWidth) {
          _acceptSize(sizeNow, media);
        }
        final stable = _media!;
        final size = _size!;
        if (ReaderRecoveryDiagnostics.observing) {
          final geometry = (
            constraints.biggest,
            media.size,
            media.padding,
            media.viewPadding,
            media.viewInsets,
            size,
            stable.padding,
            holding,
          );
          if (_diagnosticGeometry != geometry) {
            _diagnosticGeometry = geometry;
            ReaderRecoveryDiagnostics.record('contentViewport', {
              'width': constraints.maxWidth,
              'height': constraints.maxHeight,
              'stableWidth': size.width,
              'stableHeight': size.height,
              'mediaWidth': media.size.width,
              'mediaHeight': media.size.height,
              'top': media.padding.top,
              'bottom': media.padding.bottom,
              'stableTop': stable.padding.top,
              'stableBottom': stable.padding.bottom,
              'keyboard': media.viewInsets.bottom,
              'holding': holding,
            });
          }
        }
        return OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: size.height,
          maxHeight: size.height,
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              // 只保留正文几何；主题、字号缩放及其他设备偏好继续读取当前值。
              data: media.copyWith(
                size: stable.size,
                padding: stable.padding,
                viewPadding: stable.viewPadding,
                viewInsets: EdgeInsets.zero,
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
