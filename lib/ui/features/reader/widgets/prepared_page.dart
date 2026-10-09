import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../domain/models/book_document.dart';
import 'page_canvas.dart';
import 'turn_trace.dart';

/// 一页内容的绘制材料。只解码正文图片，不对整页抓图。
/// 调用方须等 load 完成再展示，并在替换或丢弃过期结果时 dispose。
class PreparedPage {
  PreparedPage._(this.page, this._images);

  final PageCanvas page;
  final Map<String, ImageInfo?> _images;

  /// 动画交给静态页时共享已解码图片，各自持有可独立释放的引用。
  PreparedPage clone() => PreparedPage._(page, {
    for (final entry in _images.entries) entry.key: entry.value?.clone(),
  });

  /// 纯文字页同步就绪，翻页时不插入一帧加载画面。
  static PreparedPage? textOnly(PageCanvas page) =>
      page.layout
              .page(page.pageIndex)
              ?.fragments
              .any(
                (f) => f.imageSize != null && f.block.resourcePath != null,
              ) ==
          true
      ? null
      : PreparedPage._(page, {});

  static Future<PreparedPage> load(
    PageCanvas page,
    ImageConfiguration configuration,
  ) async {
    final paths = <String>{
      for (final fragment in page.layout.page(page.pageIndex)?.fragments ?? [])
        if (fragment.block.kind == BlockKind.image &&
            fragment.block.resourcePath != null &&
            fragment.imageSize != null)
          fragment.block.resourcePath!,
    };
    // 只记录页坐标、资源个数和耗时，不输出正文或图片路径。
    final label = 'simplified images chapter=${page.layout.chapterId} '
        'page=${page.pageIndex} count=${paths.length}';
    final images = await traceTurnStep(label, () => Future.wait(
      paths.map(
        (path) => traceTurnStep('$label image=${paths.toList().indexOf(path)} '
            'svg=${path.toLowerCase().endsWith('.svg')}',
            () => _loadPageImage(File(page.resolveResource(path)), configuration)),
      ),
    ));
    return PreparedPage._(page, Map.fromIterables(paths, images));
  }

  /// SVG 也先生成固定图像，避免扫描中出现占位后补图。
  static Future<ImageInfo?> _loadPageImage(File file, ImageConfiguration configuration) async {
    if (!file.path.toLowerCase().endsWith('.svg')) {
      return _loadImage(FileImage(file), configuration);
    }
    try {
      final picture = await vg.loadPicture(SvgFileLoader(file), null);
      final ratio = configuration.devicePixelRatio ?? 1;
      final recorder = ui.PictureRecorder();
      (Canvas(recorder)..scale(ratio)).drawPicture(picture.picture);
      final scaled = recorder.endRecording();
      try {
        return ImageInfo(image: scaled.toImageSync(
          (picture.size.width * ratio).ceil(), (picture.size.height * ratio).ceil()), scale: ratio);
      } finally { scaled.dispose(); picture.picture.dispose(); }
    } on Object { return null; }
  }

  /// 复用 Flutter 图片缓存；持有监听器给出的 ImageInfo，释放时不清全局缓存。
  /// 动图固定为取得的首帧，保证同一次折页的正反面内容一致。
  static Future<ImageInfo?> _loadImage(
    ImageProvider provider,
    ImageConfiguration configuration,
  ) async {
    final result = Completer<ImageInfo?>();
    final stream = provider.resolve(configuration);
    final listener = ImageStreamListener(
      (info, _) {
        if (result.isCompleted) {
          info.dispose();
        } else {
          result.complete(info);
        }
      },
      onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) result.complete(null);
      },
    );
    stream.addListener(listener);
    try {
      return await result.future;
    } finally {
      stream.removeListener(listener);
    }
  }

  /// size 是包含页边距的整页尺寸；正文仍按排版时的尺寸居中，不能重新断行。
  void paint(Canvas canvas, Size size, {PageCanvas? appearance}) {
    final page = appearance ?? this.page;
    final content = page.layout.contentSize;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = page.theme.background);
    page.information?.paint(canvas, size, paintMenu: false);
    canvas.translate(
      (size.width - content.width) / 2,
      (size.height - content.height + (page.information?.top ?? 0) -
          (page.information?.bottom ?? 0)) / 2,
    );
    page.paintText(canvas);
    for (final fragment in page.layout.page(page.pageIndex)?.fragments ?? []) {
      final imageSize = fragment.imageSize;
      final path = fragment.block.resourcePath;
      if (fragment.frameOnly || fragment.block.kind != BlockKind.image ||
          imageSize == null ||
          path == null) {
        continue;
      }
      final rect = Offset(fragment.block.tableId == null ? 0 : fragment.block.inset, fragment.y) & imageSize;
      final image = _images[path];
      if (image != null) {
        paintImage(
          canvas: canvas,
          rect: rect,
          image: image.image,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.medium,
        );
      } else {
        // 与静态页一样，失败时保留原图尺寸和替代文字，不改变后续正文位置。
        canvas.drawRect(
          rect,
          Paint()..color = page.theme.secondary.withValues(alpha: 0.08),
        );
        final alt = fragment.block.alt;
        final label = TextPainter(
          text: TextSpan(
            text: alt?.isNotEmpty == true ? alt : '图片无法显示',
            style: TextStyle(fontSize: 12, color: page.theme.secondary,
              fontFamily: page.information?.fontFamily),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          textScaler: page.layout.options.textScaler,
        )..layout(maxWidth: rect.width);
        canvas.save();
        canvas.clipRect(rect);
        label.paint(
          canvas,
          rect.center - Offset(label.width / 2, label.height / 2),
        );
        canvas.restore();
        label.dispose();
      }
    }
    canvas.restore();
    page.information?.searchMenu?.paint(canvas, size);
  }

  void dispose() {
    for (final image in _images.values) {
      image?.dispose();
    }
    _images.clear();
  }
}
