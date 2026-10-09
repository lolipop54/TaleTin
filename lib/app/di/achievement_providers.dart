import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/drift_achievement_repository.dart';
import '../../domain/repositories/achievement_repository.dart';
import '../../domain/services/achievement_service.dart';
import '../../domain/rules/achievement_rules.dart';
import 'app_providers.dart';

final achievementRepositoryProvider=Provider<AchievementRepository>(
  (ref)=>DriftAchievementRepository(ref.watch(appDatabaseProvider)));
final achievementServiceProvider=Provider<AchievementService>((ref) {
  final service=AchievementService(ref.watch(achievementRepositoryProvider));
  ref.onDispose(service.dispose);
  return service;
});
final achievementPageProvider=StreamProvider<AchievementEvaluation>((ref) async* {
  final service=ref.watch(achievementServiceProvider);
  await service.initialize();
  yield* service.watch();
});
