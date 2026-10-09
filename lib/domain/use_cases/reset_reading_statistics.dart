import '../services/reading_statistics_service.dart';
import '../services/achievement_service.dart';
import '../repositories/statistics_settings_repository.dart';

class ResetReadingStatistics {
  ResetReadingStatistics(this.statistics, this.repository, this.achievements);
  final ReadingStatisticsService statistics;
  final StatisticsSettingsRepository repository;
  final AchievementService achievements;
  Future<void> run() async {
    await statistics.reset(repository.clearStatistics);
    await achievements.refresh();
  }
}
