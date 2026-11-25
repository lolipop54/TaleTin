import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 底部弹层的背景使用整个窗口宽度，左右和底部由各面板内部的 SafeArea 避让。
class EdgeToEdgeSheet extends StatelessWidget {
  const EdgeToEdgeSheet({
    super.key,
    required this.child,
    this.fullHeight = false,
  });

  final Widget child;
  final bool fullHeight;

  @override
  Widget build(BuildContext context) {
    // ModalBottomSheetRoute 会移除顶部 padding。单独从窗口读取实时状态栏高度，
    // 正文仍使用弹层原有的 MediaQuery（包括字号、键盘和分屏约束）。
    final content = MediaQuery(data: MediaQuery.of(context), child: child);
    return MediaQuery.fromView(
      view: View.of(context),
      child: Builder(
        builder: (windowContext) {
          final top = MediaQuery.paddingOf(windowContext).top;
          if (fullHeight) {
            // 全高图库的底色延伸到状态栏后方，只让其内容向下移动。
            return SizedBox.expand(
              child: Padding(
                padding: EdgeInsets.only(top: top),
                child: content,
              ),
            );
          }
          // 短面板贴合正文，键盘或大字号使内容占满高度时才需要顶部避让。
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(0, MediaQuery.sizeOf(context).height - top),
            ),
            child: content,
          );
        },
      ),
    );
  }
}
