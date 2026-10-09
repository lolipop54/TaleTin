import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/repositories/statistics_settings_repository.dart';
import '../../data/repositories/drift_statistics_settings_repository.dart';
import '../../domain/use_cases/reset_reading_statistics.dart';
import 'app_providers.dart';
import 'statistics_providers.dart';
import 'achievement_providers.dart';

final statisticsSettingsRepositoryProvider = Provider<StatisticsSettingsRepository>(
  (ref) => DriftStatisticsSettingsRepository(ref.watch(appDatabaseProvider)));
final statisticsSettingsProvider = AsyncNotifierProvider<StatisticsSettingsNotifier,
    StatisticsSettings>(StatisticsSettingsNotifier.new);
final resetReadingStatisticsProvider = Provider((ref) => ResetReadingStatistics(
  ref.watch(readingStatisticsServiceProvider), ref.watch(statisticsSettingsRepositoryProvider),
  ref.watch(achievementServiceProvider)));

class StatisticsSettingsNotifier extends AsyncNotifier<StatisticsSettings> {
  Future<void> _writing = Future.value();
  @override
  Future<StatisticsSettings> build() async {
    final value = await ref.watch(statisticsSettingsRepositoryProvider).load();
    ref.read(readingStatisticsServiceProvider).setIdleMinutes(value.idleMinutes);
    return value;
  }
  Future<void> change({int? idleMinutes, bool? includeAudio}) {
    final operation = _writing.then((_) async {
      final repo = ref.read(statisticsSettingsRepositoryProvider);
      final old = await repo.load();
      final value = StatisticsSettings(idleMinutes: idleMinutes ?? old.idleMinutes,
        includeAudio: includeAudio ?? old.includeAudio);
      await repo.save(value);
      if (!ref.mounted) return;
      ref.read(readingStatisticsServiceProvider).setIdleMinutes(value.idleMinutes);
      state = AsyncData(value);
    });
    _writing = operation.catchError((Object _) {});
    return operation;
  }
}
