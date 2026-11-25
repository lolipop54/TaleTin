part of 'book_page_footer.dart';

/// 完整纸面保留在独立绘制层。页码变化时，仅在它可能出现的小区域重新取纸面颜色。
class _CurlPageFooter extends StatefulWidget {
  const _CurlPageFooter({
    required this.paper,
    required this.size,
    required this.current,
    required this.target,
  });
  final FoldFramesPainter paper;
  final Size size;
  final BookPageFooter current, target;
  @override
  State<_CurlPageFooter> createState() => _CurlPageFooterState();
}

class _CurlPageFooterState extends State<_CurlPageFooter> {
  bool _live = false;
  Object? _font;
  double _lineHeight = 0;
  final _first = _PageInkCache(), _second = _PageInkCache();

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, first = w.current;
    final defaults = DefaultTextStyle.of(context);
    final style = defaults.style.merge(first.style);
    final direction = Directionality.of(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final font = (first.info.fontFamily, first.info.scaler);
    if (_font != font) {
      _font = font;
      _lineHeight = first.info.footerLineHeight;
    }
    final base = RepaintBoundary(
      child: CustomPaint(painter: w.paper, willChange: true),
    );
    return ListenableBuilder(
      listenable: first.count,
      child: base,
      builder: (context, body) {
        final firstLabel = first.label, secondLabel = w.target.label;
        Rect? prepare(_PageInkCache cache, String? label) => cache.prepare(
          label,
          style,
          first,
          direction,
          defaults.textHeightBehavior,
          w.size,
          _lineHeight,
          ratio,
        );
        final a = prepare(_first, firstLabel),
            b = prepare(_second, secondLabel);
        final band = a == null
            ? b
            : b == null
            ? a
            : a.expandToInclude(b);
        // 若起手前已算完，全程只绘制一次完整卷页。起手时还在计数的纸面
        // 保留正文绘制层直到落页，最后一次计数通知也只会更新页脚。
        _live = _live || first.loading;
        if (!_live) {
          return Semantics(
            label: firstLabel,
            child: CustomPaint(
              willChange: true,
              painter: w.paper.withInk(
                _first.ink(first),
                _second.ink(w.target),
              ),
            ),
          );
        }
        final screen = Offset.zero & w.size;
        final regions = <Rect>[];
        final dirty = band == null
            ? const <Rect>[]
            : w.paper.inkRegions(w.size, band);
        for (final r in dirty) {
          // 包含纹理滤波边缘，按设备像素对齐，小区域与下方整页共用同一采样原点。
          final rect = Rect.fromLTRB(
            (r.left * ratio - 2).floor() / ratio,
            (r.top * ratio - 2).floor() / ratio,
            (r.right * ratio + 2).ceil() / ratio,
            (r.bottom * ratio + 2).ceil() / ratio,
          ).intersect(screen);
          if (rect.isEmpty) continue;
          if (regions.isNotEmpty && regions.first.overlaps(rect)) {
            regions[0] = regions.first.expandToInclude(rect);
          } else {
            regions.add(rect);
          }
        }
        return IgnorePointer(
          child: Semantics(
            label: firstLabel,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (w.paper.frames.paper.a == 1)
                  body!
                else
                  ClipPath(clipper: _OutsideInk(regions), child: body),
                for (final rect in regions)
                  Positioned.fromRect(
                    rect: rect,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _LocalPaperPaint(
                          w.paper,
                          w.size,
                          rect,
                          _first,
                          _second,
                          first,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OutsideInk extends CustomClipper<Path> {
  const _OutsideInk(this.regions);
  final List<Rect> regions;
  @override
  Path getClip(Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    for (final region in regions) {
      path.addRect(region);
    }
    return path;
  }

  @override
  bool shouldReclip(_OutsideInk old) => old.regions != regions;
}

class _PageInkCache {
  TextPainter? _text;
  Object? _textKey, _inkKey;
  PageInk? _ink;
  Rect? _bounds;
  double _scale = 1, _ratio = 1;
  Offset _origin = Offset.zero;

  Rect? prepare(
    String? label,
    TextStyle style,
    BookPageFooter footer,
    TextDirection direction,
    ui.TextHeightBehavior? behavior,
    Size size,
    double height,
    double ratio,
  ) {
    final info = footer.info;
    final key = (label, style, direction, behavior, info.scaler);
    if (_textKey != key) {
      _text?.dispose();
      _text = label == null
          ? null
          : (TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: direction,
              textScaler: info.scaler,
              textHeightBehavior: behavior,
              maxLines: 1,
            )..layout());
      _textKey = key;
      _inkKey = null;
    }
    final text = _text;
    if (text == null) return _bounds = null;
    final rowWidth = text.width + (footer.loading ? 13 : 0);
    _scale = math.min(
      1,
      math.min(
        _labelWidth(size.width, info.inset) / rowWidth,
        height / math.max(text.height, footer.loading ? 9.0 : 0.0),
      ),
    );
    _ratio = ratio;
    final top = size.height - info.footerBottomPadding - height;
    final leftPx = ((info.inset - 1).floor() * ratio).floor(),
        topPx = ((top - 1).floor() * ratio).floor();
    final rightPx = ((info.inset + rowWidth * _scale) * ratio).ceil() + 1,
        bottomPx = ((top + height) * ratio).ceil() + 1;
    _origin = Offset(
      info.inset - leftPx / ratio,
      top + height / 2 - topPx / ratio,
    );
    return _bounds = Rect.fromLTRB(
      leftPx / ratio,
      topPx / ratio,
      rightPx / ratio,
      bottomPx / ratio,
    );
  }

  PageInk? ink(BookPageFooter footer) {
    final bounds = _bounds, text = _text;
    if (bounds == null || text == null) return null;
    final key = (
      bounds,
      _scale,
      _ratio,
      _origin,
      footer.loading ? footer.phase.value : -1,
    );
    if (_inkKey == key) return _ink;
    _ink?.dispose();
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder)
      ..translate(_origin.dx, _origin.dy)
      ..scale(_scale);
    text.paint(c, Offset(0, -text.height / 2));
    if (footer.loading) {
      c.translate(text.width + 4, -4.5);
      _PageCountMark(
        footer.info.color,
        footer.phase,
      ).paint(c, const Size.square(9));
    }
    _inkKey = key;
    return _ink = PageInk(recorder.endRecording(), bounds, _ratio);
  }

  void dispose() {
    _text?.dispose();
    _ink?.dispose();
  }
}

class _LocalPaperPaint extends CustomPainter {
  _LocalPaperPaint(
    this.paper,
    this.sheet,
    this.rect,
    this.first,
    this.second,
    this.footer,
  ) : super(repaint: footer.loading ? footer.phase : null);
  final FoldFramesPainter paper;
  final Size sheet;
  final Rect rect;
  final _PageInkCache first, second;
  final BookPageFooter footer;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size, doAntiAlias: false);
    canvas.translate(-rect.left, -rect.top);
    paper.paintWithInk(
      canvas,
      sheet,
      current: first.ink(footer),
      target: second.ink(footer),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LocalPaperPaint old) => true;
}

/// 静止页与翻动页使用同一笔画和时钟，交接时圆弧的方向和大小一致。
class _PageCountMark extends CustomPainter {
  _PageCountMark(this.color, this.phase) : super(repaint: phase);
  final Color color;
  final ValueListenable<int> phase;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawArc(
    (Offset.zero & size).deflate(.5),
    (phase.value - 1) * math.pi / 2,
    .65 * 2 * math.pi,
    false,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1,
  );

  @override
  bool shouldRepaint(_PageCountMark old) =>
      old.color != color || old.phase != phase;
}
