import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../../engine/layout/book_background.dart';
import '../../../../engine/styles/property_parsers.dart';
import '../../../../engine/styles/style_value.dart';

typedef BookImageLookup = ImageInfo? Function(String path);

/// 定位按「可用尺寸减去图片尺寸」计算百分比；cover/contain 始终保留原比例。
/// 原始图片句柄由页准备或滚动资源持有，这里只画已准备好的像素。
void paintCssBackground(
  Canvas canvas,
  Rect clip,
  Rect area,
  BookBackgroundImage background,
  BookImageLookup? lookup,
) {
  final info = lookup?.call(background.path);
  if (info == null || area.isEmpty || clip.isEmpty) return;
  final image = info.image;
  final style = background.style;
  LengthContext context(double reference) => LengthContext(
    fontSize: background.fontSize,
    rootFontSize: background.rootFontSize,
    reference: reference,
    viewportWidth: area.width,
    viewportHeight: area.height,
  );
  double? length(String token, double reference) => token == 'auto'
      ? null
      : StyleParser.length(token)?.resolve(context(reference));
  final native = Size(image.width / info.scale, image.height / info.scale);
  var width = native.width, height = native.height;
  final size = (style.size ?? 'auto').trim().toLowerCase();
  if (size == 'cover' || size == 'contain') {
    final x = area.width / width, y = area.height / height;
    final scale = size == 'cover' ? math.max(x, y) : math.min(x, y);
    width *= scale;
    height *= scale;
  } else {
    final tokens = StyleParser.splitTokens(size);
    final w = tokens.isEmpty ? null : length(tokens[0], area.width);
    final h = tokens.length < 2 ? null : length(tokens[1], area.height);
    if (w != null) width = w;
    if (h != null) height = h;
    if (w != null && h == null) height = width * native.height / native.width;
    if (h != null && w == null) width = height * native.width / native.height;
  }
  if (width <= 0 || height <= 0) return;
  var repeats = (style.repeat ?? 'repeat').trim().toLowerCase().split(
    RegExp(r'\s+'),
  );
  if (repeats.first == 'repeat-x') repeats = ['repeat', 'no-repeat'];
  if (repeats.first == 'repeat-y') repeats = ['no-repeat', 'repeat'];
  final rx = repeats.first, ry = repeats.length > 1 ? repeats[1] : rx;
  final dimensions = StyleParser.splitTokens(size);
  final autoX = dimensions.isNotEmpty && dimensions.first == 'auto';
  final autoY =
      dimensions.length < 2 && size != 'cover' && size != 'contain' ||
      dimensions.length > 1 && dimensions[1] == 'auto';
  if (rx == 'round') {
    final old = width;
    width = area.width / math.max(1, (area.width / width).round());
    if (ry != 'round' && autoY) {
      height *= width / old;
    }
  }
  if (ry == 'round') {
    final old = height;
    height = area.height / math.max(1, (area.height / height).round());
    if (rx != 'round' && autoX) width *= height / old;
  }
  final (px, py) = _position(style.position ?? '0% 0%');
  final x = area.left + px.offset(area.width, width, context(area.width));
  final y = area.top + py.offset(area.height, height, context(area.height));
  final xs = _spaces(rx, area.left, area.width, width, x);
  final ys = _spaces(ry, area.top, area.height, height, y);
  canvas.save();
  canvas.clipRect(clip);
  // 普通平铺由 shader 完成，不在一像素纹理上逐张循环绘制。
  for (final dx in xs ?? [x]) {
    for (final dy in ys ?? [y]) {
      final repeatX = rx == 'repeat' || rx == 'round',
          repeatY = ry == 'repeat' || ry == 'round';
      canvas.save();
      // 不重复的轴先裁出图片范围，再 clamp 采样，避免放大图片边缘混入透明色。
      canvas.clipRect(
        Rect.fromLTRB(
          repeatX ? clip.left : math.max(clip.left, dx),
          repeatY ? clip.top : math.max(clip.top, dy),
          repeatX ? clip.right : math.min(clip.right, dx + width),
          repeatY ? clip.bottom : math.min(clip.bottom, dy + height),
        ),
      );
      final matrix = Float64List.fromList([
        width / image.width,
        0,
        0,
        0,
        0,
        height / image.height,
        0,
        0,
        0,
        0,
        1,
        0,
        dx,
        dy,
        0,
        1,
      ]);
      final shader = ui.ImageShader(
        image,
        repeatX ? TileMode.repeated : TileMode.clamp,
        repeatY ? TileMode.repeated : TileMode.clamp,
        matrix,
        filterQuality: FilterQuality.medium,
      );
      canvas.drawRect(clip, Paint()..shader = shader);
      shader.dispose();
      canvas.restore();
    }
  }
  canvas.restore();
}

List<double>? _spaces(
  String repeat,
  double start,
  double span,
  double tile,
  double positioned,
) {
  if (repeat != 'space') return null;
  final count = (span / tile).floor();
  if (count < 2) return [positioned];
  final step = (span - tile) / (count - 1);
  return [for (var i = 0; i < count; i++) start + i * step];
}

class _Axis {
  const _Axis(this.anchor, [this.length, this.edge = false]);
  final double anchor;
  final Length? length;
  final bool edge;
  double offset(double span, double image, LengthContext context) {
    final free = span - image;
    if (length == null) return free * anchor;
    if (!edge && length is PercentLength) {
      return free * (length! as PercentLength).value;
    }
    final offset = length!.resolve(context);
    return edge ? free * anchor + (anchor == 1 ? -offset : offset) : offset;
  }
}

(_Axis, _Axis) _position(String raw) {
  final tokens = raw.toLowerCase().trim().split(RegExp(r'\s+'));
  _Axis? x, y;
  if (tokens.length <= 2) {
    var a = tokens.first, b = tokens.length == 1 ? 'center' : tokens[1];
    if (a == 'top' || a == 'bottom' || b == 'left' || b == 'right') {
      final swap = a;
      a = b;
      b = swap;
    }
    _Axis axis(String value) => switch (value) {
      'center' => const _Axis(.5),
      'right' || 'bottom' => const _Axis(1),
      'left' || 'top' => const _Axis(0),
      _ => _Axis(0, StyleParser.length(value)),
    };
    return (axis(a), axis(b));
  }
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token == 'left' ||
        token == 'right' ||
        token == 'top' ||
        token == 'bottom') {
      final length = i + 1 < tokens.length
          ? StyleParser.length(tokens[i + 1])
          : null;
      if (length != null) i++;
      final axis = _Axis(
        token == 'right' || token == 'bottom' ? 1 : 0,
        length,
        true,
      );
      if (token == 'left' || token == 'right') {
        x = axis;
      } else {
        y = axis;
      }
    } else if (token == 'center') {
      if (x == null) {
        x = const _Axis(.5);
      } else {
        y = const _Axis(.5);
      }
    }
  }
  return (x ?? const _Axis(.5), y ?? const _Axis(.5));
}
