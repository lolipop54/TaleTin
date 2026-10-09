import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/gt_tokens.dart';
import 'cover_art.dart';
import 'cover_art_spec.dart';
import 'decorations.dart';

/// 书籍封面。
///
/// 导入时提取到本地封面图（[imagePath]）时优先显示真实封面，图片按格子
/// 尺寸拉伸填满（`BoxFit.fill`），不裁切中间；
/// 没有封面或图片不可读时，按 bookId 取一套图案样式 [CoverSpec] 画占位封面
/// （设计文档 2.1：缺失封面用书名与稳定配色生成），不会出现空白格子。
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.bookId,
    required this.title,
    required this.author,
    this.imagePath,
    this.imageBytes,
    this.radius = GtRadius.cover,
  });

  final String bookId;
  final String title;
  final String author;

  /// 封面图绝对路径；null 表示没有封面
  final String? imagePath;
  final Uint8List? imageBytes;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final spec = CoverSpec.of(bookId);
    return AspectRatio(
      aspectRatio: GtSize.coverAspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final path = imagePath;
            if (imageBytes case final bytes?) {
              return Image.memory(bytes, fit: BoxFit.fill,
                gaplessPlayback: true,
                cacheWidth: (w * MediaQuery.devicePixelRatioOf(context)).round(),
                errorBuilder: (context, error, stack) => _placeholder(w, spec));
            }
            if (path != null) {
              // 只按格子宽度解码，避免大封面图占满内存
              final cacheWidth =
                  (w * MediaQuery.devicePixelRatioOf(context)).round();
              return Image.file(
                File(path),
                // 按格子尺寸拉伸填满，不裁切图片中间（宁可轻微变形也不丢内容）
                fit: BoxFit.fill,
                cacheWidth: cacheWidth <= 0 ? null : cacheWidth,
                errorBuilder: (context, error, stack) => _placeholder(w, spec),
              );
            }
            return _placeholder(w, spec);
          },
        ),
      ),
    );
  }

  /// 书名占位封面：图案 + 文字，跟随封面宽度等比缩放。
  Widget _placeholder(double w, CoverSpec spec) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: CoverArtPainter(spec)),
        _buildText(w, spec),
      ],
    );
  }

  Widget _buildText(double w, CoverSpec spec) {
    switch (spec.titleLayout) {
      case CoverTitleLayout.center:
        return _centeredBlock(w, spec, atBottom: false);
      case CoverTitleLayout.lower:
        return _centeredBlock(w, spec, atBottom: true);
      case CoverTitleLayout.rightVertical:
        return _verticalLayout(w, spec);
    }
  }

  /// 居中（或偏下）排布：书名在上，副题、作者依次向下。
  Widget _centeredBlock(double w, CoverSpec spec, {required bool atBottom}) {
    // 字号随封面宽度缩放，格子变小时整体等比缩小
    final titleSize = (w * 0.13).clamp(9.0, 26.0);
    final smallSize = (w * 0.07).clamp(6.0, 12.0);
    final block = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: w * 0.04),
          child: Text(
            // 中文书名放不下时断成均衡两行（参考图里「云边有个／小卖部」的排法）
            _wrapTitle(title, titleSize, w * 0.92),
            maxLines: 3,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontSize: titleSize,
              height: 1.28,
              fontWeight: FontWeight.w600,
              color: spec.titleColor,
              letterSpacing: titleSize * 0.04,
            ),
          ),
        ),
        if (spec.subtitle != null) ...[
          SizedBox(height: w * 0.06),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: w * 0.10),
            child: Text(
              spec.subtitle!,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: smallSize,
                height: 1.35,
                letterSpacing: smallSize * 0.12,
                color: spec.authorColor,
              ),
            ),
          ),
        ],
        if (spec.showCoverAuthor) ...[
          SizedBox(height: w * 0.05),
          Text(
            author,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontSize: smallSize,
              color: spec.authorColor,
            ),
          ),
        ],
      ],
    );
    if (atBottom) {
      // 偏下：标题块底部对齐到封面 84% 处
      return Align(
        alignment: const Alignment(0, 0.32),
        child: Padding(
          padding: EdgeInsets.only(left: w * 0.04, right: w * 0.04),
          child: block,
        ),
      );
    }
    return Align(
      alignment: spec.titleAlign,
      child: Padding(
        padding: EdgeInsets.only(left: w * 0.04, right: w * 0.04),
        child: block,
      ),
    );
  }

  /// 竖排书名 + 左上小字作者（仿参考图里「活着」「挪威的森林」的排布）。
  Widget _verticalLayout(double w, CoverSpec spec) {
    final titleSize = (w * 0.16).clamp(9.0, 28.0);
    final smallSize = (w * 0.062).clamp(5.5, 11.0);
    return Stack(
      children: [
        // 竖排书名：靠右
        Positioned(
          top: w * 0.16,
          right: w * 0.16,
          child: VerticalText(
            title,
            spacing: titleSize * 0.16,
            style: TextStyle(
              fontSize: titleSize,
              height: 1.05,
              fontWeight: FontWeight.w600,
              color: spec.titleColor,
            ),
          ),
        ),
        // 竖排作者：左上
        Positioned(
          top: w * 0.14,
          left: w * 0.16,
          child: VerticalText(
            author,
            spacing: smallSize * 0.2,
            style: TextStyle(fontSize: smallSize, color: spec.authorColor),
          ),
        ),
        if (spec.subtitle != null)
          Positioned(
            left: w * 0.14,
            bottom: w * 0.14,
            child: Text(
              spec.subtitle!,
              style: TextStyle(
                fontSize: smallSize,
                color: spec.authorColor,
                letterSpacing: 1,
              ),
            ),
          ),
      ],
    );
  }
}

/// 中文书名自动断行：一行放不下时折成尽量均衡的两行，避免出现单个孤字。
String _wrapTitle(String title, double fontSize, double maxWidth) {
  // 中文字形实际占宽略大于字号，按 1.06 倍估算可避免「最后一行只剩一个字」
  final perLine = (maxWidth / (fontSize * 1.06)).floor();
  if (perLine <= 0 || title.length <= perLine) return title;
  if (title.length <= perLine * 2) {
    final first = (title.length / 2).ceil();
    final head = title.substring(0, first);
    final tail = title.substring(first);
    return '$head\n$tail';
  }
  return title; // 过长时交给 Text 自动折行
}
