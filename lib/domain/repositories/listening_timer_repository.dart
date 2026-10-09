/// 只保存用户最后选择的分钟数，不保存运行中的倒计时；0 表示不定时。
abstract interface class ListeningTimerRepository {
  Future<int?> loadMinutes();
  Future<void> saveMinutes(int minutes);
}
