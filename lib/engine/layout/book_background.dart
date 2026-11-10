import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import '../styles/chapter_styler.dart';
import '../styles/computed_style.dart';
import 'layout_options.dart';
import 'display_box_layout.dart';
import 'resolve_block_box.dart';
import 'measured_block.dart';
export 'background_image_style.dart';

// 同一正文对象的来源和样式表不变。翻页时只取根背景，不必为每次
// 图片准备、文字绘制和页图再解码整章元素。空结果也缓存，离开正文可回收。
final _chapterBackgroundStyles = Expando<({ComputedStyle? style})>();

/// html 背景为空时，body 背景传播到阅读纸面。两者不重复叠加。
ComputedStyle? _chapterBackgroundStyle(ChapterContent content) {
  return (_chapterBackgroundStyles[content] ??= (
    style: _resolveChapterBackgroundStyle(content),
  )).style;
}

ComputedStyle? _resolveChapterBackgroundStyle(ChapterContent content) {
  final source = DisplaySourceIndex.fromJson(content.displaySourceJson);
  if (source == null) return null;
  final table = ChapterStyler.layoutTableOf(content);
  for (final tag in ['html', 'body']) {
    final element = source.elements.where((e) => e.tag == tag).firstOrNull;
    if (element == null) continue;
    final style = table[element.styleId ?? 0];
    final background = style.box.background;
    if ((background?.color?.argb ?? 0) == 0 && background?.imageUrl == null) {
      continue;
    }
    return style;
  }
  return null;
}

String? chapterBackgroundPath(ChapterContent content) =>
    _chapterBackgroundStyle(content)?.box.background?.imageUrl;
BlockBox? chapterBackground(ChapterContent content, LayoutOptions options) {
  final style = _chapterBackgroundStyle(content);
  return style == null
      ? null
      : resolveBlockBox(
          BoxStyleSpec(background: style.box.background),
          DisplayBoxLayout.context(style, options, options.contentWidth),
        );
}

Iterable<String> blockBackgroundPaths(MeasuredBlock block) sync* {
  for (final box in [
    block.box,
    block.codeBox,
    ...block.containerBoxes.map((f) => f.box),
    ...block.inlineBoxes.map((f) => f.box),
  ]) {
    if (box?.backgroundImage case final image?) yield image.path;
  }
}

/// 包括未命中的条件样式，换主题后不需要在界面上补读资源。
Set<String> chapterImageResources(ChapterContent content) => {
  for (final b in content.blocks) ...{
    if (b.resourcePath != null) b.resourcePath!,
    for (final i in b.inlineImages) i.resourcePath,
  },
  for (final path
      in content.displaySourceJson?['backgroundResources'] as List? ?? const [])
    if (path is String && path.startsWith('res/')) path,
};
