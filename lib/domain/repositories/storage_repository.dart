typedef InstalledStorage = ({
  int packageBytes,
  int bundledDictionaryBytes,
  int extractedDictionaryBytes,
});

typedef WindowsProgramStorage = ({int directoryBytes, int bundledFontBytes});

class StorageUsage {
  const StorageUsage(
    this.categories,
    this.clearableBytes, {
    this.installed,
    this.windowsProgram,
  });
  final Map<String, int> categories;
  final int clearableBytes;
  final InstalledStorage? installed;
  final WindowsProgramStorage? windowsProgram;

  // 随包词库和内置字体分别已计入 APK 和 Windows 应用目录。
  int get totalBytes =>
      categories.values.fold(0, (a, b) => a + b) +
      (installed?.packageBytes ?? 0) +
      (installed?.extractedDictionaryBytes ?? 0) +
      (windowsProgram?.directoryBytes ?? 0);
}

abstract interface class StorageRepository {
  Future<StorageUsage> load();
  Future<void> clearCache();
}
