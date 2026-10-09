class BackupCancelled implements Exception {
  const BackupCancelled();
  @override
  String toString() => '操作已取消';
}

class BackupOperation {
  BackupOperation({this.onProgress});
  final void Function(String phase, int done, int total)? onProgress;
  bool cancelled = false;
  void check() { if (cancelled) throw const BackupCancelled(); }
  void report(String phase, int done, int total) {
    check(); onProgress?.call(phase, done, total);
  }
}
