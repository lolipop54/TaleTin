class ReadingControls {
  const ReadingControls({
    this.keepAwake = false,
    this.volumeKeys = false,
    this.swipeUpToExit = false,
    this.statusBar = true,
    this.navigationBar = true,
  });
  final bool keepAwake, volumeKeys, swipeUpToExit, statusBar, navigationBar;
}

abstract interface class ReadingControlsRepository {
  Future<ReadingControls> load();
  Future<void> save(ReadingControls value);
}
