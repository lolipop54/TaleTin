import 'dart:math' as math;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pdfrx_engine/pdfrx_engine.dart';

/// 一些图文PDF把整页白底与插图合成一张背景图，再叠加可复制文字。
/// 这里遮去已有文字的位置，按剩余图形的连通区域找插图；只分析像素，不做OCR。
Future<List<List<double>>> pdfVisualRegions(
  PdfPage page,
  PdfPageRawText? text,
) async {
  const width = 480;
  final height = (width * page.height / page.width).round().clamp(1, 3000);
  final raster = await page.render(
    width: width,
    height: height,
    fullWidth: width.toDouble(),
    fullHeight: height.toDouble(),
    backgroundColor: 0xffffffff,
  );
  if (raster == null) return [];
  try {
    final data = (
      Uint8List.fromList(raster.pixels),
      width,
      height,
      [
        for (final r in text?.charRects ?? const <PdfRect>[])
          r.rotate(page.rotation.index, page),
      ],
      page.width,
      page.height,
    );
    // 连通区域分析只处理像素和矩形，放到后台，不能在界面线程扫描整页。
    return await Isolate.run(() => _findRegions(data));
  } finally {
    raster.dispose();
  }
}

List<List<double>> _findRegions(
  (Uint8List, int, int, List<PdfRect>, double, double) data,
) {
  final (pixels, width, height, rects, pageWidth, pageHeight) = data;
  // 四像素网格足以识别插图外框，也避免让纸张噪点变成成千上万的小图片。
  const cell = 4;
  final columns = (width + cell - 1) ~/ cell,
      rows = (height + cell - 1) ~/ cell;
  final occupied = Uint8List(columns * rows);
  final erased = Uint8List(width * height);
  for (final original in rects) {
    if (original.isEmpty) continue;
    final box = original;
    final left = (box.left / pageWidth * width - 2).floor().clamp(0, width);
    final right = (box.right / pageWidth * width + 2).ceil().clamp(0, width);
    final top = ((1 - box.top / pageHeight) * height - 2).floor().clamp(
      0,
      height,
    );
    final bottom = ((1 - box.bottom / pageHeight) * height + 2).ceil().clamp(
      0,
      height,
    );
    for (var y = top; y < bottom; y++) {
      erased.fillRange(y * width + left, y * width + right, 1);
    }
  }
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (erased[y * width + x] != 0) continue;
      final offset = (y * width + x) * 4;
      if (math.min(
            pixels[offset],
            math.min(pixels[offset + 1], pixels[offset + 2]),
          ) <
          242) {
        final index = (y ~/ cell) * columns + x ~/ cell;
        if (occupied[index] < 255) occupied[index]++;
      }
    }
  }
  final result = <List<double>>[];
  for (var start = 0; start < occupied.length; start++) {
    if (occupied[start] < 2) continue;
    final queue = <int>[start];
    occupied[start] = 0;
    var left = start % columns,
        right = left,
        top = start ~/ columns,
        bottom = top;
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final at = queue[cursor], x = at % columns, y = at ~/ columns;
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
      for (var ny = math.max(0, y - 1); ny <= math.min(rows - 1, y + 1); ny++) {
        for (
          var nx = math.max(0, x - 1);
          nx <= math.min(columns - 1, x + 1);
          nx++
        ) {
          final next = ny * columns + nx;
          if (occupied[next] >= 2) {
            occupied[next] = 0;
            queue.add(next);
          }
        }
      }
    }
    final w = right - left + 1, h = bottom - top + 1;
    if (w < 4 || h < 3 || w * h / (columns * rows) < .002) continue;
    final box = [
      math.max(0.0, (left * cell - 3) / width),
      math.max(0.0, (top * cell - 3) / height),
      math.min(1.0, (w * cell + 6) / width),
      math.min(1.0, (h * cell + 6) / height),
    ];
    box[2] = math.min(box[2], 1 - box[0]);
    box[3] = math.min(box[3], 1 - box[1]);
    if (box[2] * box[3] < .75) result.add(box);
  }
  // 相邻的图框、标签和图例属于同一张插图，合并后按原页区域一次渲染。
  var merged = true;
  while (merged) {
    merged = false;
    outer:
    for (var i = 0; i < result.length; i++) {
      for (var j = i + 1; j < result.length; j++) {
        final a = result[i], b = result[j];
        final dx = math.max(a[0], b[0]) - math.min(a[0] + a[2], b[0] + b[2]);
        final dy = math.max(a[1], b[1]) - math.min(a[1] + a[3], b[1] + b[3]);
        if (dx < .025 && dy < .025) {
          final x = math.min(a[0], b[0]), y = math.min(a[1], b[1]);
          result[i] = [
            x,
            y,
            math.max(a[0] + a[2], b[0] + b[2]) - x,
            math.max(a[1] + a[3], b[1] + b[3]) - y,
          ];
          result.removeAt(j);
          merged = true;
          break outer;
        }
      }
    }
  }
  return result;
}
