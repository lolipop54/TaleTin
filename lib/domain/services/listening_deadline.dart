/// 单调毫秒时钟及原生停止提醒，不使用墙上时间。
abstract class ListeningDeadline {
  Future<int> now();
  Future<void> arm(int version, int? deadlineMs);
  Stream<int> get expired;
}
