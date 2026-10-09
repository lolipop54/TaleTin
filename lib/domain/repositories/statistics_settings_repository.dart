class StatisticsSettings {
  const StatisticsSettings({this.idleMinutes = 5, this.includeAudio = true});
  final int idleMinutes;
  final bool includeAudio;
}
abstract interface class StatisticsSettingsRepository {
  Future<StatisticsSettings> load();
  Future<void> save(StatisticsSettings value);
  Future<void> clearStatistics();
}
