import 'dart:ui';

/// 即将进入屏幕或可能回翻的正文共用这些文字和矢量边框绘制指令。
class ScrollTextPictures {
  // 连续快划再向回读时，保留最近看过的文字指令。位图由图片缓存单独管理。
  static const _maxPictures = 256;
  static const _maxBytes = 4 * 1024 * 1024;
  final _pictures = <Object, Picture>{};
  var _bytes = 0;

  void paint(Canvas canvas, Object key, void Function(Canvas) draw) {
    final cached = _pictures.remove(key);
    if (cached != null) {
      _pictures[key] = cached;
      canvas.drawPicture(cached);
      return;
    }
    final picture = _record(draw);
    canvas.drawPicture(picture);
    _store(key, picture);
  }

  /// 与屏内绘制共用一份指令。已存在时不改变最近使用次序。
  bool prepare(Object key, void Function(Canvas) draw) {
    if (_pictures.containsKey(key)) return false;
    _store(key, _record(draw));
    return true;
  }

  /// 让图形线程按设备像素首次画出这段字。上屏仍然重放矢量指令，以便
  /// 在任意滚动偏移处保持字形清晰。这里只暂借一张小画布，不缓存位图。
  Future<void> warmGlyphs(Object key, Size size, double pixelRatio) async {
    final picture = _pictures[key];
    final width = (size.width * pixelRatio).ceil();
    final height = (size.height * pixelRatio).ceil();
    if (picture == null ||
        width <= 0 ||
        height <= 0 ||
        width * height > 512 * 1024) {
      return;
    }
    final recorder = PictureRecorder();
    Canvas(recorder)
      ..scale(pixelRatio)
      ..drawPicture(picture);
    final scaled = recorder.endRecording();
    try {
      (await scaled.toImage(width, height)).dispose();
    } on Exception {
      // 设备暂时无法分配离屏画布时，仍由正常的屏幕绘制完成。
    } finally {
      scaled.dispose();
    }
  }

  Picture _record(void Function(Canvas) draw) {
    final recorder = PictureRecorder();
    try {
      draw(Canvas(recorder));
    } catch (_) {
      recorder.endRecording().dispose();
      rethrow;
    }
    return recorder.endRecording();
  }

  void _store(Object key, Picture picture) {
    if (picture.approximateBytesUsed > 2 * 1024 * 1024) {
      picture.dispose();
      return;
    }
    _bytes += picture.approximateBytesUsed;
    _pictures[key] = picture;
    while (_pictures.length > _maxPictures || _bytes > _maxBytes) {
      final oldest = _pictures.remove(_pictures.keys.first)!;
      _bytes -= oldest.approximateBytesUsed;
      oldest.dispose();
    }
  }

  void dispose() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
    _bytes = 0;
  }
}
