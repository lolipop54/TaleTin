import 'package:direct_read_rust/direct_read_rust.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/content_table.dart';
import '../../domain/models/display_source_index.dart';
import '../layout/display_role.dart';
import '../layout/layout_options.dart';
import 'chapter_styler.dart';
import 'computed_style.dart';
import 'computed_style_json.dart';
import 'style_table.dart';
import 'style_value.dart';
import 'style_box_value.dart';
import 'publication_typography.dart';

/// 在纸面尺寸、主题和字号已确定后计算作者样式。只更新显示引用，不重新规范化正文。
abstract final class CssLayoutStyles {
  static final _cache = Expando<Map<String, ChapterContent>>();

  static ChapterContent resolve(ChapterContent content, LayoutOptions options) {
    final source = DisplaySourceIndex.fromJson(content.displaySourceJson);
    final program = content.displaySourceJson?['css'];
    if (source == null ||
        (program is! Map && content.displaySourceJson?['computed'] != true)) {
      return content;
    }
    final key =
        '${options.contentWidth}|${options.contentHeight}|${options.settings.fontSize}|${options.cssDark}';
    final cached = _cache[content] ??= {};
    if (cached[key] case final value?) return value;
    final oldTable = ChapterStyler.layoutTableOf(content);
    Map<String, dynamic>? computed;
    if (program is Map) {
      final native = NativeHtml('<html><body></body></html>');
      try {
        computed = native.convert({
          'styleProgram': program,
          'cssEnvironment': {
            'width': options.contentWidth,
            'height': options.contentHeight,
            'fontSize': options.settings.fontSize,
            'dark': options.cssDark,
          },
        });
      } finally {
        native.close();
      }
    }
    // 无条件规则的样式已经解码，同一章内多个元素可复用同一条记录。
    final staticColumns =
        computed == null &&
            content.tables.any((table) => table.columnNodes != null)
        ? {
            for (final element in source.elements)
              element.nodeId: oldTable[element.styleId ?? 0],
          }
        : const <int, ComputedStyle>{};
    final table = StyleTable();
    final rawDeclared = content.displaySourceJson?['fontSizeDeclarations'];
    final declaredNodes = rawDeclared is List ? rawDeclared.toSet() : null;
    final declared = computed != null
        ? <int>{
            for (final element in source.elements)
              if ((computed['${element.nodeId}']
                      as Map?)?['fontSizeDeclared'] ==
                  true)
                element.id,
          }
        : declaredNodes != null
        ? <int>{
            for (final element in source.elements)
              if (declaredNodes.contains(element.nodeId)) element.id,
          }
        : null;
    final headingDefaults = <(int, int), int>{};
    final elementIds = <int, int>{};
    final elementStyles = {
      for (final element in source.elements)
        element.id: computed == null
            ? oldTable[element.styleId ?? 0]
            : computedStyleFromJson(computed['${element.nodeId}']),
    };
    final fontBasis = PublicationTypography.fontBasis(
      content,
      source,
      elementStyles,
    );
    final normalizedIds = Map<ComputedStyle, int>.identity();
    for (final element in source.elements) {
      final style = elementStyles[element.id]!;
      elementIds[element.id] = normalizedIds.putIfAbsent(
        style,
        () => table.intern(PublicationTypography.normalize(style, fontBasis)),
      );
    }
    final byBlock = <int, List<(int, DisplayTextRange)>>{};
    for (final e in source.elements) {
      for (final range in e.ranges) {
        (byBlock[range.block] ??= []).add((e.id, range));
      }
    }
    final blocks = <ContentBlock>[];
    for (var index = 0; index < content.blocks.length; index++) {
      final block = content.blocks[index];
      final listItem = block.kind == BlockKind.paragraph
          ? source
                .chainOfBlock(index)
                .reversed
                .where((e) => e.role == 'listItem')
                .firstOrNull
          : null;
      // li 内的 p 是列表项的正文，不是额外的一段普通正文。只在显示副本
      // 为该项首块接回标记；后续段落不重复画标记，原文与位置保持不变。
      final listStart =
          listItem != null &&
          listItem.firstBlock == index &&
          displayOf(listItem, table[elementIds[listItem.id] ?? 0]) ==
              DisplaySpec.listItem;
      final owner = source.ownerOfBlock(index);
      // 只取当前元素已登记的样式，不能把旧祖先框接回正文块。
      final sid = elementIds[owner?.id] ?? 0;
      final own = table[sid];
      final ranges = byBlock[index] ?? const <(int, DisplayTextRange)>[];
      final runs = <TextRun>[];
      var offset = 0;
      for (final run in block.runs) {
        final end = offset + run.text.length;
        final boundaries = <int>{offset, end};
        for (final (_, range) in ranges) {
          if (range.start > offset && range.start < end) {
            boundaries.add(range.start);
          }
          if (range.end > offset && range.end < end) boundaries.add(range.end);
        }
        final points = boundaries.toList()..sort();
        for (var part = 0; part + 1 < points.length; part++) {
          final start = points[part], stop = points[part + 1];
          // 后序元素覆盖祖先；每个范围引用同一份 UTF-16 原文。
          var element = owner?.id;
          for (final (id, range) in ranges) {
            if (range.start <= start && range.end >= stop) element = id;
          }
          var styleId = element == null
              ? table.intern(oldTable[run.styleId ?? 0])
              : elementIds[element];
          if (block.kind == BlockKind.heading &&
              owner != null &&
              declared != null) {
            // 只在标题自身及其内部查找字号声明，父级 body 的 1em 只是继承值。
            // 在正式排版入口合成默认增量，不能让低层测量测试绕过本步骤而漏测。
            var current = element;
            var explicit = false;
            while (current != null) {
              if (declared.contains(current)) explicit = true;
              if (current == owner.id) break;
              current = source.element(current)?.parent;
            }
            if (!explicit) {
              final key = (styleId ?? 0, block.level ?? 1);
              styleId = headingDefaults.putIfAbsent(key, () {
                final style = table[key.$1];
                final size = style.text.fontSize;
                final inherited = size is RelativeFontSize ? size.factor : 1.0;
                final json = computedStyleToJson(style);
                final text = Map<String, Object?>.from(json['t'] as Map? ?? {});
                // 这是按本次读者字号生成的显示副本，不写回作者样式或正文。
                text['fs'] = RelativeFontSize(
                  inherited +
                      headingSizeDelta(block.level) / options.settings.fontSize,
                ).toJson();
                json['t'] = text;
                return table.intern(computedStyleFromJson(json));
              });
            }
          }
          runs.add(
            TextRun(
              run.text.substring(start - offset, stop - offset),
              link: run.link,
              footnote: run.footnote,
              styleId: styleId,
            ),
          );
        }
        offset = end;
      }
      blocks.add(
        ContentBlock(
          id: block.id,
          kind: listStart
              ? BlockKind.listItem
              : owner?.tag == 'p' &&
                    PublicationTypography.isHeading(
                      block,
                      own,
                      runs
                          .where((r) => r.text.trim().isNotEmpty)
                          .map((r) => table[r.styleId ?? 0]),
                    )
              ? BlockKind.heading
              : block.kind,
          runs: runs,
          level: block.level,
          resourcePath: block.resourcePath,
          resourceWidth: block.resourceWidth,
          resourceHeight: block.resourceHeight,
          alt: block.alt,
          target: block.target,
          nest: block.nest,
          ordered: listStart
              ? source.element(listItem.parent ?? -1)?.tag == 'ol'
              : block.ordered,
          ordinal: listStart ? listItem.listOrdinal : block.ordinal,
          breaks: block.breaks,
          indents: block.indents,
          isQuoteContainer: block.isQuoteContainer,
          // 盒子身份取真实产生元素。旧转换阶段可能在下一个标题开始时
          // 才输出前一 div 的直接文字，遗留 boxId 会把两个兄弟元素连成一框。
          boxId: owner?.id,
          parentBox: block.parentBox,
          line: block.line,
          inlineImages: [
            for (final image in block.inlineImages)
              InlineImage(
                offset: image.offset,
                resourcePath: image.resourcePath,
                width: image.width,
                height: image.height,
                alt: image.alt,
                imageWidth: image.imageWidth,
                imageMaxWidth: image.imageMaxWidth,
                styleId:
                    elementIds[ranges
                        .where(
                          (r) =>
                              source.elements[r.$1].role == 'image' &&
                              r.$2.start == image.offset,
                        )
                        .firstOrNull
                        ?.$1],
              ),
          ],
          inlineBoxes: [
            for (final (id, range) in ranges)
              if (isInlineDisplay(
                    displayOf(source.elements[id], table[elementIds[id] ?? 0]),
                  ) &&
                  !table[elementIds[id] ?? 0].box.isEmpty)
                InlineBoxSpan(
                  start: range.start,
                  end: range.end,
                  id: id,
                  styleId: elementIds[id],
                  box: const [],
                ),
          ],
          weight: block.weight,
          styleId: sid,
        ),
      );
    }
    final display = <String, Object?>{
      ...content.displaySourceJson!,
      if (computed != null) 'fontFaces': computed['fontFaces'],
      'elements': [
        for (final element in source.elements)
          {...element.toJson(), 's': elementIds[element.id]},
      ],
    };
    final result = ChapterContent(
      chapterId: content.chapterId,
      blocks: blocks,
      tables: [
        for (final value in content.tables)
          ContentTable(
            value.cells,
            value.columns,
            value.rows,
            box: value.box,
            boxId: value.boxId,
            columnWidths: value.columnWidths,
            columnNodes: value.columnNodes,
            columnStyles: value.columnNodes == null
                ? null
                : [
                    for (final id in value.columnNodes!)
                      table.intern(
                        computed == null
                            ? staticColumns[id] ?? ComputedStyle.empty
                            : computedStyleFromJson(computed['$id']),
                      ),
                  ],
          ),
      ],
      epubDetailsRevision: content.epubDetailsRevision,
      pdfPage: content.pdfPage,
      stylesJson: table.toJson(),
      displaySourceJson: display,
    );
    // 一章仅保留最近两个显示环境，避免拖动窗口或字号时积累旧样式副本。
    if (cached.length >= 2) cached.remove(cached.keys.first);
    cached[key] = result;
    return result;
  }
}
