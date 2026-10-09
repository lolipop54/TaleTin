import '../rules/achievement_rules.dart';

abstract interface class AchievementRepository {
  /// 读取事实、计算条件和首次解锁在同一事务中完成。
  Future<AchievementEvaluation> evaluate({bool silently = false});
  Stream<void> get changes;
  /// 播放前先持久化消费；中断可少播一次，但不能重启反复播。
  Future<bool> claim(String id);
}
