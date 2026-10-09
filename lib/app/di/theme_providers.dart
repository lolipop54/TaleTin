import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/repositories/app_theme_repository.dart';
import '../../data/repositories/drift_app_theme_repository.dart';
import 'app_providers.dart';

final appThemeRepositoryProvider = Provider<AppThemeRepository>(
  (ref) => DriftAppThemeRepository(ref.watch(appDatabaseProvider)));
final initialAppThemeProvider = Provider<AppThemeMode>((ref) => AppThemeMode.system);
final appThemeProvider = NotifierProvider<AppThemeNotifier, AppThemeMode>(AppThemeNotifier.new);

class AppThemeNotifier extends Notifier<AppThemeMode> {
  bool _saving = false;
  @override
  AppThemeMode build() => ref.watch(initialAppThemeProvider);

  Future<void> select(AppThemeMode mode) async {
    if (_saving) return;
    _saving = true;
    try {
      // 写入成功才换主题，磁盘失败时保留原画面。
      await ref.read(appThemeRepositoryProvider).save(mode);
      if (ref.mounted) state = mode;
    } finally { _saving = false; }
  }
}
