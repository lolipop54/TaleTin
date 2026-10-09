import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/drift_reading_statistics_repository.dart';
import '../../domain/repositories/reading_statistics_repository.dart';
import '../../domain/services/reading_statistics_service.dart';
import 'app_providers.dart';

final readingStatisticsRepositoryProvider = Provider<ReadingStatisticsRepository>(
  (ref) => DriftReadingStatisticsRepository(ref.watch(appDatabaseProvider)));

/// 正式启动注入已完成恢复的实例；独立阅读器测试也共用一个应用级实例。
final readingStatisticsServiceProvider = Provider<ReadingStatisticsService>((ref) {
  final service = ReadingStatisticsService(ref.watch(readingStatisticsRepositoryProvider),
    onError: (error) => debugPrint('阅读统计保存失败，将重试：$error'));
  service.startHeartbeat();
  ref.onDispose(service.dispose);
  return service;
});
