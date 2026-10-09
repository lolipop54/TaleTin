import 'package:flutter/widgets.dart';

/// 首页数据准备完成后通知隐藏页面先构建完整内容，再显示可操作的书架。
class MainPagesReady extends InheritedWidget {
  const MainPagesReady({
    super.key,
    required this.ready,
    this.isCurrent = true,
    required super.child,
  });
  final bool ready;

  /// 最外层页面/弹层遮住主界面时，隐藏分支不能继续展示成就奖励。
  final bool isCurrent;
  static bool isCurrentOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MainPagesReady>()?.isCurrent ??
      true;
  static void dependOn(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MainPagesReady>();
  @override
  bool updateShouldNotify(MainPagesReady oldWidget) =>
      ready != oldWidget.ready || isCurrent != oldWidget.isCurrent;
}
