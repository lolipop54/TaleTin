import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pdfium_flutter/pdfium_flutter.dart' as native;
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../../../core/diagnostics/reader_work_trace.dart';

/// PDFium负责字体、裁剪、透明图片及矢量绘制；所有调用经过引擎的原生任务串行器。
/// 本类不访问平台通道，因此导入和按需资源准备均可在后台isolate使用。
class PdfFile {
  PdfFile._(this.document);
  final PdfDocument document;
  static Future<void>? _initializing;
  static Future<PdfFile> open(String path) async {
    // Android后台isolate没有HOME环境变量；显式使用系统临时目录，且不复制源书。
    await traceReaderWork(
      'pdf.initialize',
      () =>
          _initializing ??= pdfrxInitialize(tmpPath: Directory.systemTemp.path),
    );
    return PdfFile._(
      await traceReaderWork(
        'pdf.open_document',
        () => PdfDocument.openFile(path),
      ),
    );
  }

  Future<Uint8List> render(
    int index,
    int width, {
    List<double> box = const [0, 0, 1, 1],
  }) async {
    final data = await raster(index, width, box: box);
    // 需要落盘的电子书图片在后台编码；原页显示直接使用像素，省掉PNG往返。
    return Isolate.run(() => _encode(data));
  }

  Future<(int, int, Uint8List)> raster(
    int index,
    int width, {
    List<double> box = const [0, 0, 1, 1],
  }) async {
    final page = document.pages[index];
    width = math.min(
      width,
      math.max(
        1,
        math
            .sqrt(4000000 * page.width * box[2] / (page.height * box[3]))
            .floor(),
      ),
    );
    final scale = width / (page.width * box[2]);
    final fullWidth = page.width * scale, fullHeight = page.height * scale;
    final image = await traceReaderWork(
      'pdf.raster',
      () => page.render(
        x: (box[0] * fullWidth).round(),
        y: (box[1] * fullHeight).round(),
        width: width,
        height: math.max(1, (box[3] * fullHeight).round()),
        fullWidth: fullWidth,
        fullHeight: fullHeight,
        backgroundColor: 0xffffffff,
      ),
      {'page': index, 'width': width},
    );
    if (image == null) throw const FormatException('PDF页面无法绘制');
    final data = (image.width, image.height, Uint8List.fromList(image.pixels));
    image.dispose();
    return data;
  }

  static Uint8List _encode((int, int, Uint8List) data) => Uint8List.fromList(
    img.encodePng(
      img.Image.fromBytes(
        width: data.$1,
        height: data.$2,
        bytes: data.$3.buffer,
        order: img.ChannelOrder.bgra,
      ),
      level: 1,
    ),
  );

  /// 用PDFium自己的坐标变换取得图像/图形边界，包含页面旋转与CropBox。
  /// 复杂Form作为一个完整插图区域保留，避免拆散遮罩、裁剪和矢量图。
  Future<List<List<double>>> illustrations(int index) =>
      document.useNativeDocumentHandle((address) {
        final api = native.pdfiumBindings;
        final doc = Pointer<native.fpdf_document_t__>.fromAddress(address);
        final page = api.FPDF_LoadPage(doc, index);
        if (page == nullptr) throw const FormatException('PDF页面无法读取');
        final width = document.pages[index].width.round();
        final height = document.pages[index].height.round();
        try {
          return using((arena) {
            final left = arena<Float>(), bottom = arena<Float>();
            final right = arena<Float>(), top = arena<Float>();
            final dx = arena<Int>(), dy = arena<Int>();
            final result = <List<double>>[];
            void collect(
              native.FPDF_PAGEOBJECT object,
              List<double> matrix,
              int depth,
            ) {
              final type = api.FPDFPageObj_GetType(object);
              if (type == 5 && depth < 32) {
                final m = arena<native.FS_MATRIX>();
                if (api.FPDFPageObj_GetMatrix(object, m) == 0) return;
                final n = m.ref;
                final combined = [
                  matrix[0] * n.a + matrix[2] * n.b,
                  matrix[1] * n.a + matrix[3] * n.b,
                  matrix[0] * n.c + matrix[2] * n.d,
                  matrix[1] * n.c + matrix[3] * n.d,
                  matrix[0] * n.e + matrix[2] * n.f + matrix[4],
                  matrix[1] * n.e + matrix[3] * n.f + matrix[5],
                ];
                for (var i = 0; i < api.FPDFFormObj_CountObjects(object); i++) {
                  collect(
                    api.FPDFFormObj_GetObject(object, i),
                    combined,
                    depth + 1,
                  );
                }
                return;
              }
              if (type != 3 && type != 2 && type != 4) return;
              if (api.FPDFPageObj_GetBounds(object, left, bottom, right, top) ==
                  0) {
                return;
              }
              final xs = <double>[], ys = <double>[];
              for (final x in [left.value, right.value]) {
                for (final y in [bottom.value, top.value]) {
                  api.FPDF_PageToDevice(
                    page,
                    0,
                    0,
                    width,
                    height,
                    0,
                    matrix[0] * x + matrix[2] * y + matrix[4],
                    matrix[1] * x + matrix[3] * y + matrix[5],
                    dx,
                    dy,
                  );
                  xs.add(dx.value / width);
                  ys.add(dy.value / height);
                }
              }
              final x = xs.reduce(math.min).clamp(0.0, 1.0);
              final y = ys.reduce(math.min).clamp(0.0, 1.0);
              final w = xs.reduce(math.max).clamp(0.0, 1.0) - x;
              final h = ys.reduce(math.max).clamp(0.0, 1.0) - y;
              if (w > .025 && h > .015 && w * h > .0015) {
                result.add([x, y, w, h]);
              }
            }

            for (var i = 0; i < api.FPDFPage_CountObjects(page); i++) {
              collect(api.FPDFPage_GetObject(page, i), [1, 0, 0, 1, 0, 0], 0);
            }
            return result;
          });
        } finally {
          api.FPDF_ClosePage(page);
        }
      });

  Future<void> close() => document.dispose();
}
