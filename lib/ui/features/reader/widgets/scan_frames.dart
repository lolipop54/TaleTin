import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'page_canvas.dart';
import 'prepared_page.dart';
import 'page_information.dart';
import 'book_paper.dart';

/// 每轮仅保存两张固定画面。图片解码及整页绘制只在准备阶段执行。
class ScanFrames {
  ScanFrames(this.current, this.next);
  final ui.Image current;
  final ui.Image? next;

  /// 原书截图可能不含 Flutter 信息层；准备时合成整页，扫描途中不再补画旧信息。
  static ui.Image withInformation(
    ui.Image source,
    PageInformation info,
    Size size,
    Color paper, {
    ui.Image? backgroundImage,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(source.width / size.width, source.height / size.height);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Offset.zero & size,
      Paint(),
    );
    canvas.save();
    canvas.clipPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, info.top))
        ..addRect(
          Rect.fromLTWH(0, size.height - info.bottom, size.width, info.bottom),
        ),
    );
    paintReadingBackground(canvas, size, paper, backgroundImage);
    canvas.restore();
    info.paint(canvas, size);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(source.width, source.height);
    } finally {
      picture.dispose();
      source.dispose();
    }
  }

  static ui.Image rasterize(PreparedPage page, Size size, double ratio) {
    final recorder = ui.PictureRecorder();
    page.paint(Canvas(recorder)..scale(ratio), size);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(
        (size.width * ratio).ceil(),
        (size.height * ratio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  static Future<ScanFrames> load(
    PageCanvas current,
    PageCanvas? next,
    ImageConfiguration configuration,
    Size size,
    double ratio,
  ) async {
    final first = await PreparedPage.load(current, configuration);
    PreparedPage? second;
    ui.Image? image;
    try {
      second = next == null
          ? null
          : await PreparedPage.load(next, configuration);
      image = rasterize(first, size, ratio);
      return ScanFrames(
        image,
        second == null ? null : rasterize(second, size, ratio),
      );
    } catch (_) {
      image?.dispose();
      rethrow;
    } finally {
      first.dispose();
      second?.dispose();
    }
  }

  void dispose() {
    current.dispose();
    next?.dispose();
  }
}

/// 目标页已准备但尚未提交；无目标表示全书最后一页。
class ScanPreparation {
  ScanPreparation(this.frames, this.commit, {this.targetPage});
  final ScanFrames frames;
  final Future<void> Function()? commit;
  final Object? targetPage;
}
