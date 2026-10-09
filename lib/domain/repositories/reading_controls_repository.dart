class ReadingControls {
  const ReadingControls({
    this.keepAwake = false,
    this.volumeKeys = false,
    this.statusBar = true,
    this.navigationBar = true,
  });
  final bool keepAwake, volumeKeys, statusBar, navigationBar;
}

abstract interface class ReadingControlsRepository {
  Future<ReadingControls> load();
  Future<void> save(ReadingControls value);
}
