import 'dart:ui' as ui;

import '../../../../engine/layout/chapter_layout.dart';
import '../../../core/theme/reading_theme.dart';

/// 只保留最近三页不变的文字绘制指令，静态页与翻页动画共用。
/// 图片、书签、选区和信息行仍实时绘制；排版对象或正文颜色变更即另建结果。
class PageTextCache {
  final _pictures = <(ChapterLayout, int, ui.Color, ui.Color), ui.Picture>{};

  void paint(
    ui.Canvas canvas,
    ChapterLayout layout,
    int page,
    ReadingTheme theme,
    void Function(ui.Canvas) draw,
  ) {
    final key = (layout, page, theme.primary, theme.secondary);
    var picture = _pictures.remove(key);
    if (picture == null) {
      final recorder = ui.PictureRecorder();
      draw(ui.Canvas(recorder));
      picture = recorder.endRecording();
    }
    _pictures[key] = picture;
    while (_pictures.length > 3) {
      _pictures.remove(_pictures.keys.first)!.dispose();
    }
    canvas.drawPicture(picture);
  }

  void dispose() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
  }
}
