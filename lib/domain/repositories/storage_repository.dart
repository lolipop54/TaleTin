typedef InstalledStorage = ({
  int packageBytes,
  int bundledDictionaryBytes,
  int extractedDictionaryBytes,
});

class StorageUsage {
  const StorageUsage(this.categories, this.clearableBytes, {this.installed});
  final Map<String, int> categories;
  final int clearableBytes;
  final InstalledStorage? installed;

  // 随包词库已计入 APK，只有解压后落盘的文件才另外计入总数。
  int get totalBytes =>
      categories.values.fold(0, (a, b) => a + b) +
      (installed?.packageBytes ?? 0) +
      (installed?.extractedDictionaryBytes ?? 0);
}

abstract interface class StorageRepository {
  Future<StorageUsage> load();
  Future<void> clearCache();
}
