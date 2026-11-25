import 'dart:ui';

import 'page_ink.dart';

/// 两张不透明页图已就绪时，在同一次绘制中取出底页、正面和卷起的纸背。
/// 每次手势独占采样器，整次快拖只更新折线的几何参数。
class PageCurlTexture {
  PageCurlTexture._(this._shader, this._emptySampler);
  final Image _emptySampler;
  final _boundInk = List<PageInk?>.filled(2, null);
  final _bound = [false, false];

  final FragmentShader _shader;
  static FragmentProgram? _program;
  static Future<void>? _loading;

  static Future<void> warmUp() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      _program = await FragmentProgram.fromAsset(
        'assets/shaders/page_curl.frag',
      );
    } on Exception {
      // 当前渲染器无法提供着色器时，保留原有的网格卷页。
    }
  }

  static PageCurlTexture? create(
    Image current,
    Image under,
    Size fullSize,
    double pixelRatio,
    Color paper,
  ) {
    final shader = _program?.fragmentShader();
    if (shader == null) return null;
    shader
      ..setFloat(0, fullSize.width)
      ..setFloat(1, fullSize.height)
      ..setFloat(9, 1 / pixelRatio)
      ..setFloat(10, paper.r)
      ..setFloat(11, paper.g)
      ..setFloat(12, paper.b)
      ..setImageSampler(0, current, filterQuality: FilterQuality.low)
      ..setImageSampler(1, under, filterQuality: FilterQuality.low);
    return PageCurlTexture._(shader, current);
  }

  void paint(
    Canvas canvas,
    Size leaf,
    Offset mid,
    Offset normal,
    double radius, {
    PageInk? turning,
    PageInk? under,
  }) {
    // 页码模式只更换小纹理。百分比以及原书继续直接取原来的整页图。
    void bind(int index, PageInk? ink) {
      if (_bound[index] && identical(_boundInk[index], ink)) return;
      _bound[index] = true;
      _boundInk[index] = ink;
      final rect = ink?.bounds ?? Rect.zero;
      final start = 13 + index * 4;
      _shader
        ..setFloat(start, rect.left)
        ..setFloat(start + 1, rect.top)
        ..setFloat(start + 2, rect.width)
        ..setFloat(start + 3, rect.height)
        ..setImageSampler(
          2 + index,
          ink?.image ?? _emptySampler,
          filterQuality: FilterQuality.low,
        );
    }

    bind(0, turning);
    bind(1, under);
    _shader
      ..setFloat(2, leaf.width)
      ..setFloat(3, leaf.height)
      ..setFloat(4, mid.dx)
      ..setFloat(5, mid.dy)
      ..setFloat(6, normal.dx)
      ..setFloat(7, normal.dy)
      ..setFloat(8, radius);
    canvas.drawRect(Offset.zero & leaf, Paint()..shader = _shader);
  }

  void dispose() => _shader.dispose();
}
