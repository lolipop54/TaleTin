enum AppThemeMode {
  system('跟随系统'), light('浅色'), dark('深色');
  const AppThemeMode(this.label);
  final String label;
}

abstract interface class AppThemeRepository {
  Future<AppThemeMode> load();
  Future<void> save(AppThemeMode mode);
}
