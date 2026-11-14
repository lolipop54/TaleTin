class ReadingControls {
  const ReadingControls({
    this.keepAwake = false,
    this.volumeKeys = false,
    this.swipeUpToExit = false,
    this.statusBar = true,
    this.navigationBar = true,
    this.imageViewing = true,
    this.pdfFixedViewMode = false,
  });
  final bool keepAwake, volumeKeys, swipeUpToExit, statusBar, navigationBar;

  /// 简化排版点击正文图片时是否打开大图。
  final bool imageViewing;

  /// PDF 缩放后须确认视窗，才继续翻页或滚动。
  final bool pdfFixedViewMode;
}

abstract interface class ReadingControlsRepository {
  Future<ReadingControls> load();
  Future<void> save(ReadingControls value);
}
