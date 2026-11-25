import 'dart:math' as math;

import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';
import 'measured_block.dart';
import 'vertical_margins.dart';

/// 优先采用原书的 figure/figcaption；普通段落还需居中题注或重复图文结构。
Map<String, ContentBlock> figureCaptions(
  DisplaySourceIndex source,
  ChapterContent content,
  Set<int> hiddenBlocks,
  StyleTable styles,
) {
  final captions = <String, ContentBlock>{};
  final previousByParent = <int, int>{};
  for (final parent in source.elements) {
    for (var at = 1; at < parent.children.length; at++) {
      final image = source.element(parent.children[at - 1])!;
      final caption = source.element(parent.children[at])!;
      final i = image.firstBlock;
      if (i == null ||
          image.lastBlock != i ||
          content.blocks[i].kind != BlockKind.image ||
          (image.tag != 'img' && source.ownerOfBlock(i)?.tag != 'img') ||
          !const {'p', 'figcaption'}.contains(caption.tag) ||
          caption.firstBlock != i + 1 ||
          caption.lastBlock != i + 1 ||
          hiddenBlocks.contains(i) ||
          hiddenBlocks.contains(i + 1)) {
        continue;
      }
      final label = content.blocks[i + 1];
      if (label.kind != BlockKind.paragraph && label.kind != BlockKind.caption) {
        continue;
      }
      final grouped = parent.children.length == 2;
      final semantic =
          parent.tag == 'figure' ||
          caption.tag == 'figcaption' ||
          label.kind == BlockKind.caption;
      final centered =
          styles[caption.styleId ?? label.styleId ?? 0].block.textAlign ==
          TextAlignSpec.center;
      final containedImage =
          image.tag != 'img' || (grouped && parent.tag == 'div');
      if (semantic ||
          (containedImage &&
              label.runLength > 0 &&
              label.runLength <= 120 &&
              centered)) {
        captions[content.blocks[i].id] = label;
      }
      // 普通左对齐正文只有反复出现在独立图文组内才作图注。
      if (!grouped) continue;
      var group = parent;
      while (group.parent != null) {
        final outer = source.element(group.parent!)!;
        if (outer.children.length != 1) break;
        group = outer;
      }
      final key = group.parent;
      if (key == null) continue;
      if (previousByParent[key] == i - 2) {
        captions[content.blocks[i - 2].id] = content.blocks[i - 1];
        captions[content.blocks[i].id] = label;
      }
      previousByParent[key] = i;
    }
  }
  return captions;
}

/// 整页大图给自己的图注留位。下一张图的负边距不能跨到上一张的图注上。
MeasuredBlock fitGalleryImage(
  MeasuredBlock image,
  MeasuredBlock caption,
  double pageHeight,
  double gap,
) {
  final leading = math.max(0.0, image.leadingMargin.extent);
  final available =
      pageHeight -
      image.bodyTop -
      image.bodyBottom -
      leading -
      math.max(0.0, gap);
  // 超过整页的长图注仍从图片下方开始，其余文字交给普通文字分页。
  final captionHeight = caption.height < available || caption.lines.isEmpty
      ? caption.height
      : caption.bodyTop + caption.lines.first.height;
  final remaining = available - captionHeight;
  final size = image.imageSize!;
  final fitted = remaining > 0 && remaining < size.height
      ? size * (remaining / size.height)
      : size;
  return image.withBoxEdges(
    first: image.boxFirst,
    last: image.boxLast,
    height: fitted.height + image.bodyTop + image.bodyBottom,
    imageSize: fitted,
    flowMargins: BlockMargins(VerticalMargin.of(leading), image.trailingMargin),
  );
}

typedef PortraitEntry = ({
  ContentBlock name,
  ContentBlock portrait,
  ContentBlock bio,
});

/// 同一组兄弟中反复出现的短标题、单幅肖像和介绍。保留三个原文块各自的定位。
Map<String, PortraitEntry> portraitEntries(
  DisplaySourceIndex source,
  ChapterContent content,
  Set<int> hidden,
  StyleTable styles,
) {
  final entries = <String, PortraitEntry>{};
  ({
    int imageIndex,
    int parent,
    int? titleStyle,
    int? bodyStyle,
    PortraitEntry entry,
  })?
  previous;
  final blocks = content.blocks;
  for (var i = 1; i + 1 < blocks.length; i++) {
    final image = blocks[i];
    if (image.kind != BlockKind.image ||
        (image.resourceHeight ?? 0) <= (image.resourceWidth ?? 0)) {
      continue;
    }
    final name = blocks[i - 1], bio = blocks[i + 1];
    if (name.kind != BlockKind.paragraph && name.kind != BlockKind.heading ||
        (bio.kind != BlockKind.paragraph && bio.kind != BlockKind.caption) ||
        name.runLength == 0 ||
        name.runLength > 24 ||
        bio.runLength <= name.runLength ||
        hidden.contains(i - 1) ||
        hidden.contains(i) ||
        hidden.contains(i + 1)) {
      continue;
    }
    final title = source.ownerOfBlock(i - 1), text = source.ownerOfBlock(i + 1);
    final parent = title?.parent;
    if (parent == null || text?.parent != parent) continue;
    var picture = source.ownerOfBlock(i);
    while (picture != null &&
        picture.firstBlock == i &&
        picture.lastBlock == i &&
        picture.parent != parent &&
        picture.parent != null) {
      picture = source.element(picture.parent!);
    }
    if (picture?.parent != parent ||
        picture?.firstBlock != i ||
        picture?.lastBlock != i) {
      continue;
    }
    // 真正左右浮动或绝对定位的肖像由原书的绕排规则处理。
    if (source.chainOfBlock(i).any((e) {
      final style = styles[e.styleId ?? 0].block;
      return style.float == FloatSpec.left ||
          style.float == FloatSpec.right ||
          style.position == PositionSpec.absolute ||
          style.position == PositionSpec.fixed;
    })) {
      continue;
    }
    var groupParent = parent;
    var wrapper = source.element(parent)!;
    if (wrapper.firstBlock == i - 1 && wrapper.lastBlock == i + 1) {
      while (wrapper.parent != null) {
        final outer = source.element(wrapper.parent!)!;
        groupParent = outer.id;
        if (outer.children.length != 1) break;
        wrapper = outer;
      }
    }
    final entry = (name: name, portrait: image, bio: bio);
    if (previous != null &&
        previous.imageIndex == i - 3 &&
        previous.parent == groupParent &&
        previous.titleStyle == title!.styleId &&
        previous.bodyStyle == text!.styleId) {
      for (final group in [previous.entry, entry]) {
        entries[group.name.id] = entries[group.portrait.id] = group;
      }
    }
    previous = (
      imageIndex: i,
      parent: groupParent,
      titleStyle: title!.styleId,
      bodyStyle: text!.styleId,
      entry: entry,
    );
  }
  return entries;
}

/// 只保留介绍开头，长介绍剩下的行仍由分页器自然断开。
double biographyStartHeight(MeasuredBlock bio) => bio.lines.length <= 2
    ? bio.height
    : bio.bodyTop + bio.lines[0].height + bio.lines[1].height;

/// SVG 内嵌位图和普通 img 都以一个图片块进入排版。
String? standaloneCover(ChapterContent chapter, Set<int> hidden) {
  final source = chapter.displaySourceJson;
  final declared = source?['coverPage'] == true;
  final asset = source?['coverImage'];
  if (!declared && asset == null) return null;
  ContentBlock? image;
  for (final (i, block) in chapter.blocks.indexed) {
    if (hidden.contains(i)) continue;
    if (image != null ||
        block.kind != BlockKind.image ||
        (!declared && block.resourcePath != asset) ||
        (block.resourceWidth ?? 0) <= 0 ||
        (block.resourceHeight ?? 0) <= 0) {
      return null;
    }
    image = block;
  }
  return image?.id;
}

/// 原书声明决定首图的贴边方向；推断未声明的章首模板时才要求下一块是章题。
({String id, int edges})? chapterOpeningArtwork(
  DisplaySourceIndex source,
  ChapterContent content,
  Set<int> hidden,
  StyleTable styles,
) {
  final blocks = content.blocks;
  var i = 0;
  while (hidden.contains(i)) {
    i++;
  }
  if (i >= blocks.length || blocks[i].kind != BlockKind.image) return null;
  final image = blocks[i];
  if ((image.resourceWidth ?? 0) <= (image.resourceHeight ?? 0) ||
      (image.resourceHeight ?? 0) == 0) {
    return null;
  }
  final chain = source.chainOfBlock(i);
  int? explicit;
  for (final e in chain) {
    if (e.firstBlock == i && e.lastBlock == i) {
      explicit = styles[e.styleId ?? 0].size.bleed ?? explicit;
    }
  }
  if (explicit == null) {
    if (content.displaySourceJson?['repeatedOpening'] != true) return null;
    var j = i + 1;
    while (hidden.contains(j)) {
      j++;
    }
    final size = styles[image.styleId ?? 0].size;
    if (j >= blocks.length || blocks[j].kind != BlockKind.heading ||
        size.width is! PercentLength || (size.width as PercentLength).value != 1 ||
        size.height?.isAuto == false) {
      return null;
    }
  }
  final edges = (explicit ?? 7) & 7;
  return edges == 0 ? null : (id: image.id, edges: edges);
}
