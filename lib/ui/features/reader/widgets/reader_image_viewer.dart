import 'package:taletin/platform/channels/system_toast.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'reader_image_viewport.dart';

/// 图片解码成功后再展示，查看期间的缩放与拖动不参与正文翻页。
Future<void> showReaderImage(
  BuildContext context,
  ImageProvider provider,
) async {
  final ready = Completer<ImageInfo>();
  final stream = provider.resolve(createLocalImageConfiguration(context));
  final listener = ImageStreamListener(
    (image, _) {
      if (!ready.isCompleted) {
        ready.complete(image);
      } else {
        image.dispose();
      }
    },
    onError: (Object error, StackTrace? stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  ImageInfo? image;
  try {
    image = await ready.future;
    if (!context.mounted) return;
    await _showContent(
      context,
      RawImage(image: image.image, fit: BoxFit.contain),
      Size(image.image.width.toDouble(), image.image.height.toDouble()),
    );
  } catch (_) {
    if (context.mounted) _imageFailure();
  } finally {
    stream.removeListener(listener);
    image?.dispose();
  }
}

/// 矢量插图直接绘制已解析的图形，放大后仍保持清晰。
Future<void> showReaderSvg(BuildContext context, BytesLoader loader) async {
  PictureInfo? info;
  try {
    info = await vg.loadPicture(loader, context);
    if (!context.mounted) return;
    await _showContent(
      context,
      FittedBox(
        fit: BoxFit.contain,
        child: SizedBox.fromSize(
          size: info.size,
          child: CustomPaint(painter: _VectorImage(info)),
        ),
      ),
      info.size,
    );
  } catch (_) {
    if (context.mounted) _imageFailure();
  } finally {
    info?.picture.dispose();
  }
}

void _imageFailure() => SystemToast.show('图片无法打开，请重试').ignore();

class _VectorImage extends CustomPainter {
  const _VectorImage(this.info);
  final PictureInfo info;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPicture(info.picture);
  @override
  bool shouldRepaint(_VectorImage old) => old.info != info;
}

Future<void> _showContent(
  BuildContext context,
  Widget content,
  Size imageSize,
) async {
  final transform = TransformationController();
  final route = DialogRoute<void>(
    context: context,
    useSafeArea: false,
    barrierColor: Colors.black,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () => Navigator.of(context).pop(),
          child: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ReaderImageViewport(
                  imageSize: imageSize,
                  transform: transform,
                  onBlankTap: () => Navigator.of(context).pop(),
                  child: content,
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GtButton.icon(
                    tooltip: '关闭图片',
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black54,
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  try {
    await Navigator.of(context, rootNavigator: true).push(route);
    // pop 的 Future 早于退出动画完成；画面完全移除后才能释放原图。
    await route.completed;
  } finally {
    transform.dispose();
  }
}
