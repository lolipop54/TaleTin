/// 只约束简化排版的可延后工作；前台目标和翻页准备不等待此条件。
abstract final class LayoutWorkGate {
  static final _owners = <Object>{};
  static DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);
  /// 直接邻页绘制材料只避让实际工作，不等待较远分页的120ms安静窗口。
  static bool get turnPreparationBlocked => _owners.isNotEmpty;
  static bool get blocked =>
      turnPreparationBlocked || DateTime.now().isBefore(_quietUntil);
  static void hold(Object owner) => _owners.add(owner);
  static void release(Object owner) {
    _owners.remove(owner);
    _quietUntil = DateTime.now().add(const Duration(milliseconds: 120));
  }
}
