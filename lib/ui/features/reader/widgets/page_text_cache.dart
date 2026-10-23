import 'dart:ui' as ui;

import '../../../../core/diagnostics/reader_work_trace.dart';

import '../../../../engine/layout/chapter_layout.dart';
import '../../../core/theme/reading_theme.dart';

/// 只保留最近三页不变的文字绘制指令，静态页与翻页动画共用。
/// 图片、书签、选区和信息行仍实时绘制；排版对象或正文颜色变更即另建结果。
class PageTextCache {
  final _pictures = <(Object, int, ui.Color, ui.Color), ui.Picture>{};

  /// 与正式绘制共用同一份指令，只在空闲时提前记录，不生成额外位图。
  void prepare(
    ChapterLayout layout,
    int page,
    ReadingTheme theme,
    void Function(ui.Canvas) draw,
  ) => _picture(layout, page, theme, draw);

  ui.Picture _picture(
    ChapterLayout layout,
    int page,
    ReadingTheme theme,
    void Function(ui.Canvas) draw,
  ) {
    final key = (layout.identity, page, theme.primary, theme.secondary);
    var picture = _pictures.remove(key);
    if (picture == null) {
      final trace = ReaderWorkTrace.start('page.text_picture', {'page': page});
      final recorder = ui.PictureRecorder();
      draw(ui.Canvas(recorder));
      picture = recorder.endRecording();
      trace?.finish();
    }
    _pictures[key] = picture;
    while (_pictures.length > 3) {
      _pictures.remove(_pictures.keys.first)!.dispose();
    }
    return picture;
  }

  void paint(
    ui.Canvas canvas,
    ChapterLayout layout,
    int page,
    ReadingTheme theme,
    void Function(ui.Canvas) draw,
  ) => canvas.drawPicture(_picture(layout, page, theme, draw));

  void dispose() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
  }
}
