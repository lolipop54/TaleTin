import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../domain/models/book_document.dart';
import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/layout/measured_block.dart';
import '../../../core/theme/reading_theme.dart';
import 'book_colors.dart';
import 'book_box_paint.dart';
import 'css_background_paint.dart';
import 'reader_divider_paint.dart';

/// 分页与滚动共用文字绘制；颜色、内边距和分段位置不能在两条路径中各算一次。
class ReaderTextPainter {
  const ReaderTextPainter(
    this.options,
    this.theme, {
    this.backgroundColor,
    this.images,
  });
  final LayoutOptions options;
  final ReadingTheme theme;
  final Color? backgroundColor;
  final BookImageLookup? images;
  void paint(
    Canvas canvas,
    Size size,
    PageFragment fragment, {
    bool background = true,
  }) {
    final block = fragment.block;
    if (block.kind == BlockKind.divider) {
      paintReaderDivider(canvas, size, fragment, theme);
      return;
    }
    if (block.lines.isEmpty) return;
    // 与测量用的是同一个宽度，不用盒子宽度：两者一旦不等，行尾就会留白
    final maxWidth = block.layoutWidth ?? options.contentWidthFor(block.kind);
    final baseColor = block.kind == BlockKind.caption
        ? theme.secondary
        : theme.primary;
    // 文字要和它实际压着的底色比对比度：原书常见的“红底白字”如果按纸面
    // 判断，会被误判成看不清而翻成黑字。底色可能来自块自己的盒子，也可能
    // 来自祖先容器（例如整页红底的说明页），必须按绘制顺序从外到内叠一遍。
    Color adaptLine(int line, Color ink, Color? inlineBackground) {
      // 浅色主题保留作者字色。金色标题、橙底白字本来就可能低于自动
      // 对比度阈值，不能因此改成黑字；夜间仍按实际底色保证可读。
      if (theme.background.computeLuminance() >= .35) return ink;
      // 图片上的作者字色不能按纯色纸面翻转；透明 PNG 上的白字尤其如此。
      // 有明确行内底色时仍按该底色计算，不能让外层图片盖过内层颜色。
      final imageBehind =
          block.box?.backgroundImage != null ||
          block.codeBox?.backgroundImage != null ||
          block.containerBoxes.any(
            (f) =>
                f.box.backgroundImage != null &&
                line >= f.lineFrom &&
                line < (f.lineTo ?? block.lines.length),
          ) ||
          block.inlineBoxes.any(
            (b) => b.line == line && b.box.backgroundImage != null,
          );
      if (inlineBackground == null && imageBehind) return ink;
      final backdrop = _backdropOf(block, line);
      final surface = inlineBackground == null
          ? backdrop
          : Color.alphaBlend(
              adaptSurface(inlineBackground, backdrop),
              backdrop,
            );
      return adaptInk(
        ink,
        surface,
        surface.computeLuminance() < 0.4 ? const Color(0xFFFFFFFF) : baseColor,
      );
    }

    Color adapt(Color ink, Color? background) =>
        adaptLine(fragment.lineFrom, ink, background);
    if (background) {
      paintInlineBoxes(
        canvas,
        block,
        fragment.lineFrom,
        fragment.lineTo,
        fragment.y + block.textTopOf(fragment.lineFrom),
        maxWidth,
        theme,
        images: images,
      );
    }

    // 行内图片把文字隔成几段：按测量好的段位置逐段绘制，图片由 PreparedPage 补画。
    if (block.hasSegmentedText) {
      _paintInlineLines(canvas, fragment, maxWidth, baseColor, adaptLine);
    } else {
      var index = fragment.lineFrom;
      var top = fragment.y + block.textTopOf(fragment.lineFrom);
      while (index < fragment.lineTo) {
        final left = block.horizontalOffset(index, maxWidth);
        final justify = block.justifiesLine(index);
        final spacing = block.justifySpacingFor(
          index,
          maxWidth: maxWidth,
          enabled: justify,
          textScaler: options.textScaler,
        );
        // 不需要拉伸的连续行合并成一次绘制，减少 TextPainter 数量。
        // 上下标要逐行重画、代码行缩进各不同，这两种情况不合并。
        var end = index + 1;
        if (!block.hasScript &&
            spacing <= 0 &&
            !block.lines[index].hyphenated) {
          while (end < fragment.lineTo &&
              !block.lines[end].hyphenated &&
              block.horizontalOffset(end, maxWidth) == left &&
              !block.justifiesLine(end)) {
            end++;
          }
        }
        final painter = block.createFragmentPainter(
          lineFrom: index,
          lineTo: end,
          textScaler: options.textScaler,
          // 代码行有行首缩进，测量时按「宽度 − 缩进」折行；绘制必须用同一个
          // 宽度重排，否则重排行数对不上，会退化成不给宽度的逐行绘制、
          // 文字冲出代码框（真机实测）。
          maxWidth: block.kind == BlockKind.codeBlock
              ? math.max(1, maxWidth - block.lines[index].left)
              : maxWidth,
          color: baseColor,
          letterSpacing: spacing,
          scriptColor: block.hasScript ? const Color(0x00000000) : null,
          adaptColor: adapt,
        );
        // 重排出来的行数必须和测量一致，否则按测量位置落笔就会错位：多出来的一行
        // 会压在下一行上——真机实测过（行宽正好顶到内容宽 + 行尾标点被字体回退取成
        // 更宽的写法，整行多折一次），页面上两个字叠在一起，看着像少了字。
        // 这种就逐行画：单行不给断行宽度，不可能再折行，只会往右多出一点。
        if (painter.computeLineMetrics().length == end - index) {
          final origin = Offset(block.inset + left, top);
          painter.paint(canvas, origin);
          if (block.hasScript) {
            block.paintScripts(
              canvas,
              lineIndex: index,
              linePainter: painter,
              origin: origin,
              color: baseColor,
              textScaler: options.textScaler,
            );
          }
          painter.dispose();
          for (var i = index; i < end; i++) {
            top += block.lines[i].height;
          }
        } else {
          painter.dispose();
          for (var i = index; i < end; i++) {
            final lineJustify = block.justifiesLine(i);
            final lineSpacing = block.justifySpacingFor(
              i,
              maxWidth: maxWidth,
              enabled: lineJustify,
              textScaler: options.textScaler,
            );
            final lineLeft = block.horizontalOffset(i, maxWidth);
            final linePainter = block.createSingleLinePainter(
              lineIndex: i,
              textScaler: options.textScaler,
              color: baseColor,
              letterSpacing: lineSpacing,
              scriptColor: block.hasScript ? const Color(0x00000000) : null,
              adaptColor: adapt,
            );
            final origin = Offset(block.inset + lineLeft, top);
            if (block.kind == BlockKind.codeBlock) {
              // 兜底逐行绘制不给断行宽度，长行会往右溢出代码框；
              // 裁到这一行的可用宽度内，宁可截掉屏幕外的尾巴也不压到边框外。
              canvas.save();
              canvas.clipRect(
                Rect.fromLTWH(
                  block.inset + lineLeft,
                  top,
                  math.max(1, maxWidth - lineLeft),
                  block.lines[i].height,
                ),
              );
              linePainter.paint(canvas, origin);
              canvas.restore();
            } else {
              linePainter.paint(canvas, origin);
            }
            if (block.hasScript) {
              block.paintScripts(
                canvas,
                lineIndex: i,
                linePainter: linePainter,
                origin: origin,
                color: baseColor,
                textScaler: options.textScaler,
              );
            }
            linePainter.dispose();
            top += block.lines[i].height;
          }
        }
        index = end;
      }
    }

    // 章题下的短分隔线（参考图 03 的章首样式）；书内样式表已经给了盒子时不画
    if (block.isTitleDecoration &&
        block.box == null &&
        fragment.lineTo == block.lines.length) {
      final ruleTop = fragment.y + fragment.height - kTitleRuleThickness;
      canvas.drawRect(
        Rect.fromLTWH(0, ruleTop, kTitleRuleWidth, kTitleRuleThickness),
        Paint()..color = theme.secondary.withValues(alpha: 0.66),
      );
    }
    // 列表标记：有序列表画序号，无序列表画圆点，都是装饰、不进文本流
    if (block.marker != null && !fragment.isContinuation) {
      final textTop = fragment.y + block.textTopOf(fragment.lineFrom);
      // 无序列表的圆点直接画形状：字体里的「•」很小，不同字体大小不一，
      // 画出来比正文略大一点，看着更稳当
      final bullet = switch (block.marker) {
        '•' || '○' || '▪' => block.marker,
        _ => null,
      };
      if (bullet != null) {
        final em = options.settings.fontSize.toDouble();
        final radius = em * 0.18;
        // 用正文首行真实基线定位圆心：不同字体、行高下都和文字居中对齐
        final style = block.runStyles.isEmpty
            ? TextStyle(fontSize: em, fontFamily: options.settings.fontFamily)
            : block.runStyles.first;
        final probe = TextPainter(
          text: TextSpan(text: '国', style: style),
          textDirection: TextDirection.ltr,
          textScaler: options.textScaler,
        )..layout();
        final baseline = probe.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        );
        final fontSize = probe.height > 0 ? (style.fontSize ?? em) : em;
        probe.dispose();
        final center = Offset(
          (block.markerInset - radius).clamp(0.0, double.infinity),
          textTop + baseline - fontSize * 0.34,
        );
        final paint = Paint()..color = theme.secondary;
        switch (bullet) {
          case '○':
            paint
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1.2, em * 0.07);
            canvas.drawCircle(center, radius, paint);
          case '▪':
            canvas.drawRect(
              Rect.fromCenter(
                center: center,
                width: radius * 1.7,
                height: radius * 1.7,
              ),
              paint,
            );
          default:
            canvas.drawCircle(center, radius, paint);
        }
        return;
      }
      final style = block.runStyles.isEmpty
          ? TextStyle(
              fontSize: options.settings.fontSize.toDouble(),
              fontFamily: options.settings.fontFamily,
            )
          : block.runStyles.first;
      final painter = TextPainter(
        text: TextSpan(
          text: block.marker,
          style: style.copyWith(color: theme.secondary),
        ),
        textDirection: TextDirection.ltr,
        textScaler: options.textScaler,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          (block.markerInset - painter.width).clamp(0, double.infinity),
          // 和正文首行用同一个纵向起点：带书内盒子的列表项还要算上顶部内边距，
          // 否则序号会比文字高一截
          textTop,
        ),
      );
      painter.dispose();
    }
  }

  /// 这一块文字实际压着的底色：按绘制顺序把祖先容器、块盒子、代码盒子
  /// 依次叠到纸面上。半透明底色也和纸面混合，比较对比度时不会把整块
  /// 红底当成浅色纸面。
  Color _backdropOf(MeasuredBlock block, int line) {
    var surface = backgroundColor ?? theme.background;
    void apply(Color? background) {
      if (background == null || background.a == 0) return;
      surface = Color.alphaBlend(
        adaptSurface(background, theme.background),
        surface,
      );
    }

    final seen = <int>{};
    for (final frame in block.containerBoxes) {
      if (line < frame.lineFrom ||
          line >= (frame.lineTo ?? block.lines.length) ||
          !seen.add(frame.elementId)) {
        continue;
      }
      apply(frame.box.background);
    }
    apply(block.box?.background);
    apply(block.codeBox?.background);
    return surface;
  }

  /// 行内图片块：每行的文字段按测量位置绘制，行内的图片留给图片层。
  void _paintInlineLines(
    Canvas canvas,
    PageFragment fragment,
    double maxWidth,
    Color baseColor,
    Color Function(int, Color, Color?) adapt,
  ) {
    final block = fragment.block;
    var top = fragment.y + block.textTopOf(fragment.lineFrom);
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final line = block.lines[i];
      if (line.segments.isNotEmpty) {
        final lineLeft = block.horizontalOffset(i, maxWidth);
        for (final segment in line.segments) {
          final painter = block.createSegmentPainter(
            start: segment.start,
            end: segment.end,
            letterSpacing: segment.letterSpacing,
            textScaler: options.textScaler,
            color: baseColor,
            scriptColor: block.hasScript ? const Color(0x00000000) : null,
            adaptColor: (ink, background) => adapt(i, ink, background),
          );
          final origin = Offset(
            block.inset + lineLeft + segment.left,
            top + line.textTop + segment.top,
          );
          painter.paint(canvas, origin);
          if (segment.ruby case final ruby?) {
            final label = RubyLabel.painter(
              ruby.text,
              ruby.fontSize,
              ruby.fontFamily,
              options.textScaler,
              color: baseColor,
            );
            label.paint(
              canvas,
              origin + Offset((segment.width - ruby.width) / 2, -ruby.height),
            );
            label.dispose();
          }
          if (block.hasScript) {
            block.paintScriptsInSegment(
              canvas,
              lineIndex: i,
              segment: segment,
              segmentPainter: painter,
              origin: origin,
              color: baseColor,
              textScaler: options.textScaler,
            );
          }
          painter.dispose();
        }
      }
      top += line.height;
    }
  }
}
