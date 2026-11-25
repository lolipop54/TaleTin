import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import '../styles/chapter_styler.dart';
import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
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
    if (style.block.display == DisplaySpec.none) return null;
    final background = style.box.background;
    if ((background?.color?.alpha ?? 0) == 0 && background?.imageUrl == null) {
      continue;
    }
    return style;
  }
  return null;
}

String? chapterBackgroundPath(ChapterContent content) =>
    _chapterBackgroundStyle(content)?.box.background?.imageUrl;

BackgroundSpec? fullPageBackground(ChapterContent content) {
  final bg = _chapterBackgroundStyle(content)?.box.background;
  if (bg?.imageUrl?.startsWith('res/') != true ||
      !const {'no-repeat', 'no-repeat no-repeat'}.contains(bg!.repeat)) {
    return null;
  }
  return const {
        'cover',
        'contain',
        '100%',
        '100% auto',
        '100% 100%',
        'auto 100%',
      }.contains(bg.size)
      ? bg
      : null;
}

/// 没有前景内容时，书内的背景图仍占一张纸面。沿用章首位置，空章的块号为空串。
String? backgroundOnlyPageAnchor(ChapterContent content) {
  final path = chapterBackgroundPath(content);
  if (path == null || !path.startsWith('res/')) return null;
  final resources = content.displaySourceJson?['backgroundResources'] as List?;
  if (resources != null && !resources.contains(path)) return null;
  return content.blocks.firstOrNull?.id ?? '';
}

final _paperBoxes = Expando<Expando<({BlockBox? box})>>();

BlockBox? chapterBackground(ChapterContent content, LayoutOptions options) {
  // 滚动每一帧只改变纸纹的绘制位置。阅读宽度、字号或主题变化会产生新的参数对象。
  final boxes = _paperBoxes[content] ??= Expando<({BlockBox? box})>();
  return (boxes[options] ??= (box: _resolvePaperBox(content, options))).box;
}

BlockBox? resolveFullWidthPaper(
  ChapterContent content,
  LayoutOptions options,
) => _resolvePaperBox(content, options, fullWidth: true);

BlockBox? _resolvePaperBox(
  ChapterContent content,
  LayoutOptions options, {
  bool fullWidth = false,
}) {
  final style = _chapterBackgroundStyle(content);
  return style == null
      ? null
      : resolveBlockBox(
          BoxStyleSpec(
            background: _paperBackground(
              style.box.background!,
              fullWidth: fullWidth,
            ),
          ),
          DisplayBoxLayout.context(style, options, options.contentWidth),
        );
}

BackgroundSpec _paperBackground(
  BackgroundSpec background, {
  required bool fullWidth,
}) {
  // 有些卷首页把书名也画进背景。宽屏按 cover 从底部对齐会切掉上端，
  // 因此固定到底边的整页图改为完整铺满纸面。其他背景按 CSS 原样绘制。
  if (!fullWidth &&
      (background.attachment != 'fixed' ||
          background.size != 'cover' ||
          background.repeat != 'no-repeat' ||
          !(background.position
                  ?.toLowerCase()
                  .split(RegExp(r'\s+'))
                  .contains('bottom') ??
              false))) {
    return background;
  }
  return BackgroundSpec(
    color: background.color,
    imageUrl: background.imageUrl,
    repeat: background.repeat,
    position: background.position,
    size: fullWidth ? '100% auto' : '100% 100%',
    attachment: background.attachment,
    clip: background.clip,
  );
}

Iterable<BlockBox> blockPaintBoxes(MeasuredBlock block) sync* {
  for (final box in [
    block.box,
    block.codeBox,
    ...block.tableBackdrops.map((layer) => layer.box),
    block.tableCellBox,
    ...block.containerBoxes.map((f) => f.box),
    ...block.inlineBoxes.map((f) => f.box),
  ]) {
    if (box != null) yield box;
  }
}

Iterable<String> blockBackgroundPaths(MeasuredBlock block) sync* {
  for (final box in blockPaintBoxes(block)) {
    if (box.backgroundImage case final image?) yield image.path;
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
