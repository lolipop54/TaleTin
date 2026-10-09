import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import 'reader_performance.dart';

/// 只准备屏幕附近图片；位置和高度来自正文模型，不随解码先后改变。
class ScrollResources extends ChangeNotifier {
  ScrollResources(this.resolve);
  final String Function(String) resolve;
  final _held = <String, _ScrollImage>{};
  final _pins = <String, int>{};
  bool _disposed = false;
  final _imageIndices = Expando<List<int>>();

  List<int> _indices(ScrollChapter chapter) => _imageIndices[chapter] ??=
      [for (var i = 0; i < chapter.cells.length; i++)
        if (chapter.cells[i].measured.imageSize != null ||
            chapter.cells[i].table.any((f) => !f.frameOnly && f.imageSize != null)) i];

  Set<String> pathsNear(ScrollChapter chapter, double y, double viewport) => {
    for (final i in _indices(chapter))
      if (chapter.starts[i] + chapter.cells[i].height >= y - 600 &&
          chapter.starts[i] <= y + viewport + 1200)
        ...{
          if (chapter.cells[i].table.isEmpty && chapter.cells[i].block.resourcePath != null)
            chapter.cells[i].block.resourcePath!,
          for (final fragment in chapter.cells[i].table)
            if (!fragment.frameOnly && fragment.block.resourcePath != null) fragment.block.resourcePath!,
        },
  };

  bool ready(ScrollChapter chapter, double y, double viewport) =>
      pathsNear(chapter, y, viewport).every((path) => _held[path]?.loaded == true);

  Future<void> warm(ScrollChapter chapter, double y, double viewport) async {
    final jobs = <Future<void>>[];
    final paths = pathsNear(chapter, y, viewport);
    for (final path in paths) {
      // 新窗口准备和旧窗口滚动会重叠，等待中的图片不能被旧窗口释放。
      _pins.update(path, (n) => n + 1, ifAbsent: () => 1);
      final image = _held.putIfAbsent(path, () => _ScrollImage());
      jobs.add(image.pending ??= _load(path, image));
    }
    try { await Future.wait(jobs); }
    finally {
      for (final path in paths) {
        if (_pins[path] == 1) { _pins.remove(path); }
        else { _pins[path] = _pins[path]! - 1; }
      }
    }
  }

  Future<void> _load(String path, _ScrollImage target) async {
    final watch = readerPerformanceEnabled ? (Stopwatch()..start()) : null;
    try {
      final file = File(resolve(path));
      if (path.toLowerCase().endsWith('.svg')) {
        target.picture = await vg.loadPicture(SvgFileLoader(file), null);
      } else {
        final done = Completer<ImageInfo?>();
        final stream = FileImage(file).resolve(ImageConfiguration.empty);
        late final ImageStreamListener listener;
        listener = ImageStreamListener((info, _) {
          if (done.isCompleted) { info.dispose(); } else { done.complete(info); }
        }, onError: (Object error, StackTrace? stack) => done.complete(null));
        stream.addListener(listener);
        try { target.image = await done.future; }
        finally { stream.removeListener(listener); }
      }
    } on Object {
      // 损坏或缺失图片保留原尺寸并显示替代文字，不影响后面的阅读位置。
    }
    target.loaded = true;
    if (watch != null) {
      readerPerf('simplified.scroll.image', watch.elapsedMicroseconds,
          {'svg': path.toLowerCase().endsWith('.svg')});
    }
    if (_disposed || !identical(_held[path], target)) { target.dispose(); }
    else { notifyListeners(); }
  }

  Widget view(String path, Size size, Color color, String? alt) =>
      SizedBox(width: size.width, height: size.height,
          child: Builder(builder: (context) => CustomPaint(painter: _ScrollImagePainter(
              this, path, color, alt ?? '图片无法显示',
              Theme.of(context).textTheme.bodyMedium?.fontFamily))));

  void retain(Set<String> paths) {
    for (final path in _held.keys.toList()) {
      if (!paths.contains(path) && !_pins.containsKey(path)) {
        _held.remove(path)!.dispose();
      }
    }
  }
  @override
  void dispose() {
    _disposed = true;
    for (final image in _held.values) { image.dispose(); }
    _held.clear();
    super.dispose();
  }
}

class _ScrollImage {
  bool loaded = false;
  ImageInfo? image;
  PictureInfo? picture;
  Future<void>? pending;
  void dispose() {
    image?.dispose(); image = null;
    picture?.picture.dispose(); picture = null;
  }
}

class _ScrollImagePainter extends CustomPainter {
  _ScrollImagePainter(this.resources, this.path, this.color, this.alt, this.fontFamily)
      : super(repaint: resources);
  final ScrollResources resources;
  final String path;
  final String? fontFamily;
  // 回滑重新加载会产生新对象，画笔每次取当前对象，不能持有已释放的旧图片。
  _ScrollImage? get value => resources._held[path];
  final Color color;
  final String alt;
  @override
  void paint(Canvas canvas, Size size) {
    if (value?.image case final image?) {
      paintImage(canvas: canvas, rect: Offset.zero & size,
          image: image.image, fit: BoxFit.fill);
    } else if (value?.picture case final picture?) {
      canvas.save();
      canvas.scale(size.width / picture.size.width, size.height / picture.size.height);
      canvas.drawPicture(picture.picture);
      canvas.restore();
    } else {
      final text = TextPainter(text: TextSpan(text: alt,
          style: TextStyle(color: color, fontSize: 12, fontFamily: fontFamily)),
          textDirection: TextDirection.ltr)..layout(maxWidth: size.width);
      text.paint(canvas, Offset(0, (size.height - text.height) / 2));
      text.dispose();
    }
  }
  @override
  bool shouldRepaint(_ScrollImagePainter old) => true;
}
