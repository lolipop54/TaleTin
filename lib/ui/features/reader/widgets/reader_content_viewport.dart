import 'package:flutter/material.dart';

/// 输入框从获得焦点到键盘收起期间，正文沿用原来的窗口尺寸与安全区。
/// 面板是此组件的兄弟节点，仍能使用实时键盘高度向上让位。
class ReaderContentViewport extends StatefulWidget {
  const ReaderContentViewport({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderContentViewport> createState() => _ReaderContentViewportState();
}

class _ReaderContentViewportState extends State<ReaderContentViewport> {
  MediaQueryData? _media;
  Size? _size;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _editing = _hasEditableFocus;
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 系统栏可以先于键盘高度变化，因此获得输入焦点时就停止更新正文几何。
        // 旋转、分屏等真实窗口尺寸变化仍正常交给正文重新布局。
        final holding = _editing || media.viewInsets.bottom > 0;
        if (_media == null ||
            !holding ||
            _media!.size != media.size ||
            _size!.width != constraints.maxWidth) {
          _media = media;
          _size = constraints.biggest;
        }
        final stable = _media!;
        final size = _size!;
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
