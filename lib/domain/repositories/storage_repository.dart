class StorageUsage {
  const StorageUsage(this.categories, this.clearableBytes);
  final Map<String, int> categories;
  final int clearableBytes;
  int get totalBytes => categories.values.fold(0, (a, b) => a + b);
}
abstract interface class StorageRepository {
  Future<StorageUsage> load();
  Future<void> clearCache();
}
