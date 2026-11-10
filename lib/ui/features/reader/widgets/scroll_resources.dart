import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../engine/layout/math_typesetting.dart';

import '../../../../core/diagnostics/app_errors.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import 'reader_performance.dart';
import '../../../../engine/layout/book_background.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../core/theme/reading_theme.dart';
import 'book_colors.dart';
import 'background_image_color.dart';
import 'book_box_paint.dart';
import 'book_svg_picture.dart';

/// 只准备屏幕附近图片；位置和高度来自正文模型，不随解码先后改变。
class ScrollResources extends ChangeNotifier {
  ScrollResources(
    this.resolve, {
    this.formulaColor,
    this.readingTheme,
    this.pixelRatio,
  });
  final double Function()? pixelRatio;
  final ReadingTheme Function()? readingTheme;
  final _backdrops = Expando<Map<int, Color>>();
  final Color Function()? formulaColor;
  final String Function(String) resolve;
  final _held = <String, _ScrollImage>{};
  String _key(String path) => path.startsWith(MathTypesetting.resourcePrefix)
      ? '$path|c${formulaColor?.call().toARGB32()}'
      : path;
  _ScrollImage? _visible(String path) =>
      _held[_key(path)] ??
      _held.entries
          .where((e) => e.key.startsWith('$path|c') && e.value.loaded)
          .firstOrNull
          ?.value;
  final _pins = <String, int>{};
  bool _disposed = false;
  final _imageIndices = Expando<List<int>>();
  ui.Image? backgroundImage(String path) => backgroundInfo(path)?.image;
  ImageInfo? backgroundInfo(String path) =>
      _visible(path)?.background ?? _visible(path)?.image;
  Color backdropOf(
    ScrollChapter chapter,
    LayoutOptions options,
    ReadingTheme theme,
  ) {
    final box = chapterBackground(chapter.content, options);
    final fallback = adaptSurface(
      box?.background ?? theme.background,
      theme.background,
    );
    return _backdrops[chapter]?[theme.background.toARGB32()] ?? fallback;
  }

  List<int> _indices(ScrollChapter chapter) => _imageIndices[chapter] ??= [
    for (var i = 0; i < chapter.cells.length; i++)
      if (chapter.cells[i].measured.imageSize != null ||
          chapter.cells[i].measured.hasInlineImages ||
          blockBackgroundPaths(chapter.cells[i].measured).isNotEmpty ||
          chapter.cells[i].table.any(
            (f) =>
                blockBackgroundPaths(f.block).isNotEmpty ||
                (!f.frameOnly &&
                    (f.imageSize != null || f.block.hasInlineImages)),
          ))
        i,
  ];

  Set<String> pathsNear(ScrollChapter chapter, double y, double viewport) => {
    ?chapterBackgroundPath(chapter.content),
    for (final i in _indices(chapter))
      if (chapter.starts[i] + chapter.cells[i].height >= y - 600 &&
          chapter.starts[i] <= y + viewport + 1200) ...{
        if (chapter.cells[i].table.isEmpty &&
            chapter.cells[i].block.resourcePath != null)
          chapter.cells[i].block.resourcePath!,
        ...blockBackgroundPaths(chapter.cells[i].measured),
        for (final image in chapter.cells[i].measured.inlineImagesInLines(
          chapter.cells[i].from,
          chapter.cells[i].to,
        ))
          image.resourcePath,
        for (final fragment in chapter.cells[i].table) ...{
          ...blockBackgroundPaths(fragment.block),
          if (!fragment.frameOnly && fragment.block.resourcePath != null)
            fragment.block.resourcePath!,
          for (final image in fragment.block.inlineImagesInLines(
            fragment.lineFrom,
            fragment.lineTo,
          ))
            image.resourcePath,
        },
      },
  };

  bool ready(ScrollChapter chapter, double y, double viewport) => pathsNear(
    chapter,
    y,
    viewport,
  ).every((path) => _held[_key(path)]?.loaded == true);

  Future<void> warm(ScrollChapter chapter, double y, double viewport) async {
    final jobs = <Future<void>>[];
    final paths = pathsNear(chapter, y, viewport);
    final backgroundSize =
        Size(
          chapter.cells.fold<double>(
            1,
            (n, c) => math.max(
              n,
              (c.measured.layoutWidth ?? 0) + c.measured.inset * 2,
            ),
          ),
          viewport,
        ) *
        (pixelRatio?.call() ?? 1);
    final backgrounds = {
      ?chapterBackgroundPath(chapter.content),
      for (final cell in chapter.cells) ...blockBackgroundPaths(cell.measured),
      for (final cell in chapter.cells)
        for (final fragment in cell.table)
          ...blockBackgroundPaths(fragment.block),
    };
    final keys = paths.map(_key).toList();
    for (final path in paths) {
      // 新窗口准备和旧窗口滚动会重叠，等待中的图片不能被旧窗口释放。
      final key = _key(path);
      _pins.update(key, (n) => n + 1, ifAbsent: () => 1);
      final image = _held.putIfAbsent(key, () => _ScrollImage());
      jobs.add(
        (() async {
          await (image.pending ??= _load(
            path,
            image,
            key,
            background: backgrounds.contains(path),
            backgroundSize: backgroundSize,
          ));
          if (backgrounds.contains(path) && image.picture != null) {
            await _rasterize(image, backgroundSize);
          }
        })(),
      );
    }
    try {
      await Future.wait(jobs);
      final options = chapter.options;
      final theme = readingTheme?.call() ?? ReadingTheme.paper;
      final key = theme.background.toARGB32();
      final box = options == null
          ? null
          : chapterBackground(chapter.content, options);
      if (!_disposed &&
          box?.backgroundImage != null &&
          _backdrops[chapter]?[key] == null) {
        final rect = Offset.zero & options!.contentSize;
        final tone = await averageBackgroundColor(options.contentSize, (
          canvas,
        ) {
          canvas.drawRect(rect, Paint()..color = theme.background);
          paintBookBoxRect(canvas, rect, box!, theme, images: backgroundInfo);
        });
        (_backdrops[chapter] ??= {})[key] = tone;
      }
    } finally {
      for (final path in keys) {
        if (_pins[path] == 1) {
          _pins.remove(path);
        } else {
          _pins[path] = _pins[path]! - 1;
        }
      }
    }
  }

  Future<void> _load(
    String path,
    _ScrollImage target,
    String key, {
    bool background = false,
    Size? backgroundSize,
  }) async {
    final watch = readerPerformanceEnabled ? (Stopwatch()..start()) : null;
    try {
      final file = File(resolve(path));
      if (path.toLowerCase().endsWith('.svg')) {
        target.picture = await loadBookSvg(
          file,
          theme: path.startsWith(MathTypesetting.resourcePrefix)
              ? SvgTheme(
                  currentColor: formulaColor?.call() ?? const Color(0xff000000),
                )
              : null,
        );
        if (background) {
          await _rasterize(target, backgroundSize);
        }
      } else {
        final done = Completer<ImageInfo?>();
        final provider = FileImage(file);
        final stream = provider.resolve(ImageConfiguration.empty);
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            if (done.isCompleted) {
              info.dispose();
            } else {
              done.complete(info);
            }
          },
          onError: (Object error, StackTrace? stack) {
            AppErrors.report(
              error,
              stack ?? StackTrace.current,
              operation: '正文图片加载失败',
              notify: false,
            );
            if (!done.isCompleted) done.complete(null);
          },
        );
        stream.addListener(listener);
        try {
          target.image = await done.future;
          if (target.image == null) await provider.evict();
        } finally {
          stream.removeListener(listener);
        }
      }
    } on Object catch (error, stack) {
      AppErrors.report(error, stack, operation: '正文图片加载失败', notify: false);
      // 损坏或缺失图片保留原尺寸并显示替代文字，不影响后面的阅读位置。
    }
    target.loaded = true;
    if (watch != null) {
      readerPerf('simplified.scroll.image', watch.elapsedMicroseconds, {
        'svg': path.toLowerCase().endsWith('.svg'),
      });
    }
    if (_disposed || !identical(_held[key], target)) {
      target.dispose();
    } else {
      notifyListeners();
    }
  }

  Widget view(String path, Size size, Color color, String? alt) => SizedBox(
    width: size.width,
    height: size.height,
    child: Builder(
      builder: (context) => CustomPaint(
        painter: _ScrollImagePainter(
          this,
          path,
          color,
          alt ?? '图片无法显示',
          Theme.of(context).textTheme.bodyMedium?.fontFamily,
        ),
      ),
    ),
  );

  Future<void> _rasterize(_ScrollImage target, [Size? targetSize]) async {
    if (_disposed || target.picture == null || target.picture!.size.isEmpty) {
      return;
    }
    final picture = target.picture!;
    final scale = math.min(
      targetSize == null
          ? 1.0
          : math.max(
              targetSize.width / picture.size.width,
              targetSize.height / picture.size.height,
            ),
      4096 / math.max(picture.size.width, picture.size.height),
    );
    if ((target.background?.scale ?? 0) >= scale) return;
    if (target.backgroundPending case final pending?) {
      await pending;
      return _rasterize(target, targetSize);
    }
    final job = (() async {
      final recorder = ui.PictureRecorder();
      (Canvas(recorder)..scale(scale)).drawPicture(picture.picture);
      final sized = recorder.endRecording();
      final image = await sized.toImage(
        (picture.size.width * scale).ceil().clamp(1, 4096),
        (picture.size.height * scale).ceil().clamp(1, 4096),
      );
      sized.dispose();
      if (_disposed) {
        image.dispose();
        return;
      }
      // 放大窗口时保留旧像素，较清晰的一份准备好后再交换句柄。
      target.background?.dispose();
      target.background = ImageInfo(image: image, scale: scale);
    })();
    target.backgroundPending = job;
    try {
      await job;
    } finally {
      target.backgroundPending = null;
    }
  }

  void retain(Set<String> paths) {
    final wanted = paths.map(_key).toSet();
    for (final path in _held.keys.toList()) {
      if (!wanted.contains(path) && !_pins.containsKey(path)) {
        _held.remove(path)!.dispose();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _held.values) {
      image.dispose();
    }
    _held.clear();
    super.dispose();
  }
}

class _ScrollImage {
  bool loaded = false;
  ImageInfo? image;
  PictureInfo? picture;
  ImageInfo? background;
  Future<void>? backgroundPending;
  Future<void>? pending;
  void dispose() {
    background?.dispose();
    background = null;
    image?.dispose();
    image = null;
    picture?.picture.dispose();
    picture = null;
  }
}

class _ScrollImagePainter extends CustomPainter {
  _ScrollImagePainter(
    this.resources,
    this.path,
    this.color,
    this.alt,
    this.fontFamily,
  ) : super(repaint: resources);
  final ScrollResources resources;
  final String path;
  final String? fontFamily;
  // 回滑重新加载会产生新对象，画笔每次取当前对象，不能持有已释放的旧图片。
  _ScrollImage? get value => resources._visible(path);
  final Color color;
  final String alt;
  @override
  void paint(Canvas canvas, Size size) {
    if (value?.image case final image?) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: image.image,
        fit: BoxFit.fill,
      );
    } else if (value?.picture case final picture?) {
      canvas.save();
      canvas.scale(
        size.width / picture.size.width,
        size.height / picture.size.height,
      );
      canvas.drawPicture(picture.picture);
      canvas.restore();
    } else {
      final text = TextPainter(
        text: TextSpan(
          text: alt,
          style: TextStyle(color: color, fontSize: 12, fontFamily: fontFamily),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      text.paint(canvas, Offset(0, (size.height - text.height) / 2));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_ScrollImagePainter old) => true;
}
