/// 把样式表接到正文模型上：给没有 `styles` 的正文补表、回填 `styleId`。
///
/// 方案 2 收尾后正文模型只有正文与结构，显示语义全在样式表里，所以这里的职责很小：
/// - [decode]：读正文 JSON，旧格式（块上带显示字段）当场建表，新格式原样规范化；
/// - [apply]／[attach]：给内存里拼出来、没有样式表的正文建一张表（TXT／PDF、测试夹具）；
/// - [toStylesOnly]：把片段上残留的显示字段清掉，只留 `styleId`。
library;

import '../../domain/models/book_document.dart';
import 'block_style_input.dart';
import 'legacy_style_adapter.dart';
import 'style_table.dart';

abstract final class ChapterStyler {
  /// 只有默认样式的空表（0 号记录）：TXT／PDF 这类没有 CSS 的正文用它。
  static const Map<String, Object?> emptyTableJson = {
    'v': 1,
    'styles': [<String, Object?>{}],
  };

  /// 解码一章正文（数据层统一入口）。
  ///
  /// 旧正文 JSON 的块上还带着显示字段：解码瞬间把它们读成样式输入、建表、回填
  /// `styleId`，然后只留正文与样式表。新格式（已经带 `styles`）直接规范化后返回。
  static ChapterContent decode(Map<String, Object?> json) {
    final content = ChapterContent.fromJson(json);
    return toStylesOnly(
      content.stylesJson != null
          ? content
          : apply(content, styles: LegacyStyleAdapter.inputsOfJson(json)),
    );
  }

  /// 给没有样式表的章节补上样式表与 `styleId`；已有则原样返回。
  ///
  /// [styles] 是「每块的样式输入」（旧字段形状），与 `content.blocks` 一一对应。
  /// 不传时所有块都用默认样式——TXT／PDF 这类没有作者样式的正文就是这样。
  static ChapterContent apply(
    ChapterContent content, {
    List<BlockStyleInput?>? styles,
  }) {
    if (content.stylesJson != null) return content;
    return attach(content, styles ?? const []);
  }

  /// 按「每块的样式输入」建表，并把 `styleId` 回填到块与片段上。
  ///
  /// 转换器直接输出样式表时不需要它；这里给旧 JSON 解码与测试夹具用。
  static ChapterContent attach(
    ChapterContent content,
    List<BlockStyleInput?> styles,
  ) {
    final ids = LegacyStyleAdapter.buildTable(styles, content.blocks);
    final blocks = [
      for (var i = 0; i < content.blocks.length; i++)
        content.blocks[i].withStyleIds(ids.blockIds[i], ids.runIds[i]),
    ];
    return ChapterContent(
      chapterId: content.chapterId,
      blocks: blocks,
      tables: content.tables,
      epubDetailsRevision: content.epubDetailsRevision,
      pdfPage: content.pdfPage,
      stylesJson: ids.table.toJson(),
      displaySourceJson: content.displaySourceJson,
    );
  }

  /// 每份正文的样式表只解析一次。
  ///
  /// 同一章会被反复读取（翻页、换主题、滚动重排、检查点），每次重新解析样式表 JSON
  /// 是纯浪费；`ChapterContent` 不可变，用弱引用按对象缓存即可，不需要失效逻辑。
  static final _tables = Expando<StyleTable>();

  /// 解码本章样式表；旧缓存没有时返回 null。
  static StyleTable? tableOf(ChapterContent content) {
    final json = content.stylesJson;
    if (json == null) return null;
    return _tables[content] ??= StyleTable.fromJson(json);
  }

  /// 排版用的样式表：没有样式表的正文（TXT、PDF、测试里的合成正文）就地按旧字段建一张。
  ///
  /// 这样排版路径**永远**拿到表，量测只需要「读表」这一条分支；缺表时的建表结果
  /// 与旧字段兜底逐字节等价（`test/support/styled_content_test.dart` 守着）。
  static final _layoutTables = Expando<StyleTable>();

  static StyleTable layoutTableOf(ChapterContent content) {
    final existing = tableOf(content);
    if (existing != null) return existing;
    final cached = _layoutTables[content];
    if (cached != null) return cached;
    return _layoutTables[content] = LegacyStyleAdapter.tableOf(content).table;
  }

  /// 本章的几何样式摘要（迁移期口径：按块/片段顺序投影样式表）。
  ///
  /// 样式表缺失时返回 null——调用方要退回「整份正文摘要」，不能当成“没有样式”。
  /// 块/片段没有 `styleId` 时按默认样式 0 处理（0 本来就不写进 JSON）。
  static String? geometryDigest(ChapterContent content) {
    final table = tableOf(content);
    if (table == null) return null;
    final ids = <int>[];
    for (final block in content.blocks) {
      ids.add(block.styleId ?? kDefaultStyleId);
      if (block.parentBox case final parent?) ids.add(parent.styleId);
      for (final run in block.runs) {
        ids.add(run.styleId ?? kDefaultStyleId);
      }
    }
    return table.geometryDigestFor(ids);
  }

  /// 只保留正文与结构：去掉片段上残留的显示字段，只留 `styleId` 与样式表。
  ///
  /// 旧正文 JSON 解码时片段还带着粗体/颜色等字段（建表原料）；建完表以后这些字段
  /// 不再需要，统一由 `styleId` 指向样式表。块本来就是正文+结构，逐字段原样保留。
  static ChapterContent toStylesOnly(ChapterContent content) => ChapterContent(
    chapterId: content.chapterId,
    blocks: [
      for (final block in content.blocks)
        ContentBlock(
          id: block.id,
          kind: block.kind,
          runs: [
            for (final run in block.runs)
              TextRun(
                run.text,
                link: run.link,
                footnote: run.footnote,
                styleId: run.styleId,
              ),
          ],
          level: block.level,
          resourcePath: block.resourcePath,
          resourceWidth: block.resourceWidth,
          resourceHeight: block.resourceHeight,
          alt: block.alt,
          target: block.target,
          nest: block.nest,
          ordered: block.ordered,
          ordinal: block.ordinal,
          breaks: block.breaks,
          indents: block.indents,
          isQuoteContainer: block.isQuoteContainer,
          boxId: block.boxId,
          parentBox: block.parentBox,
          line: block.line,
          inlineImages: block.inlineImages,
          inlineBoxes: block.inlineBoxes,
          weight: block.weight,
          styleId: block.styleId,
        ),
    ],
    tables: content.tables,
    epubDetailsRevision: content.epubDetailsRevision,
    pdfPage: content.pdfPage,
    stylesJson: content.stylesJson,
    displaySourceJson: content.displaySourceJson,
  );
}
