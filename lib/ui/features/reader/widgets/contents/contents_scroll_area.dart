import 'package:flutter/material.dart';

import '../../../../core/widgets/gt_scroll_input_scope.dart';
import '../reader_sheet.dart';

/// 目录、书签、笔记与全文搜索共用的滚动区域，保留边界拉伸和真实拖动。
class ContentsScrollArea extends StatelessWidget {
  const ContentsScrollArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: GtScrollInputScope(
      behavior: const _ContentsScrollBehavior(),
      child: child,
    ),
  );
}

class _ContentsScrollBehavior extends GtScrollBehavior {
  const _ContentsScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => super.buildOverscrollIndicator(
    context,
    // 底色一起参与拉伸，透明留白不会露出面板后方的原书正文。
    ColoredBox(color: ReaderSheet.backgroundOf(context), child: child),
    details,
  );
}
