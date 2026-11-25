part of 'measured_block.dart';

/// 连续网格的一行。只有跨行格或作者要求行组避断时，首个测量块携带整份行表。
typedef TableBreakRow = ({double top, double bottom, double? avoidUntil});

/// 表头和正文行在原表格中的边界。续页只复用表头格，不重画表题或外层盒子。
typedef TableHeaderBand = ({
  double top,
  double bottom,
  double bodyTop,
  double bodyEnd,
});

/// 将已测量的文字或图片放入表格网格，沿用原块和行号。
extension MeasuredTableBlock on MeasuredBlock {
  MeasuredBlock inTable({
    required String id,
    required Rect bounds,
    required double top,
    required double unit,
    double? contentBottom,
    List<TableBreakRow> breakRows = const [],
    TableHeaderBand? headerBand,
    required bool header,
    required double width,
    List<ContainerBoxFrame> containerBoxes = const [],
    double tableBottom = 0,
    double tableMarginTop = 0,
    double tableMarginBottom = 0,
    BlockBox? tableBox,
    int? boxId,
    bool boxFirst = true,
    bool boxLast = true,
    bool positionedOverlay = false,
    double? horizontalShift,
    double? cellInset,
    BlockBox? cellBox,
    List<TableBackdrop> backdrops = const [],
    bool collapsedBorders = false,
    List<TableHorizontalBorder> horizontalBorders = const [],
    List<TableVerticalBorder> verticalBorders = const [],
    bool authorStyle = false,
  }) => MeasuredBlock(
    blockId: blockId,
    kind: kind,
    level: level,
    text: text,
    runs: runs,
    runStyles: runStyles,
    lines: lines,
    height: height,
    imageSize: imageSize,
    imageFit: imageFit,
    resourcePath: resourcePath,
    alt: alt,
    noteLink: noteLink,
    altIsFootnote: altIsFootnote,
    inset:
        (horizontalShift ?? bounds.left) +
        (cellInset ?? (id.startsWith('__parallel_') ? inset : 4)),
    isDecoration: isDecoration,
    decorationAtStart: decorationAtStart,
    displayPrefixLength: displayPrefixLength,
    tableId: id,
    // 表格普通正文按阅读设置两端对齐；表头保留作者的居中/右对齐。
    align: authorStyle || header || kind != BlockKind.paragraph ? align : null,
    justify: authorStyle || header || kind != BlockKind.paragraph
        ? justify
        : true,
    hasScript: hasScript,
    tableBounds: bounds,
    tableTop: top,
    tableContentBottom: contentBottom,
    tableBreakRows: breakRows,
    tableHeaderBand: headerBand,
    positionedOverlay: positionedOverlay,
    tableUnit: unit,
    tableHeader: header,
    tableCellBox: cellBox,
    tableBackdrops: backdrops,
    collapsedTableBorders: collapsedBorders,
    tableHorizontalBorders: horizontalBorders,
    tableVerticalBorders: verticalBorders,
    tableBox: tableBox,
    layoutWidth: width,
    box: id.startsWith('__parallel_') ? box : null,
    // 图文绕排沿用每块自己的外观；表格的外框由分页生成的盒子片段绘制。
    boxId: id.startsWith('__parallel_') ? this.boxId : boxId,
    containerBoxes: containerBoxes,
    bodyTop: id.startsWith('__parallel_') ? bodyTop : 0,
    bodyBottom: id.startsWith('__parallel_') ? bodyBottom : tableBottom,
    boxFirst: boxFirst,
    boxLast: boxLast,
    textStyle: textStyle,
    inlineImages: inlineImages,
    inlineBoxes: inlineBoxes,
    marker: authorStyle || id.startsWith('__parallel_') ? marker : null,
    markerInset: authorStyle
        ? bounds.left + (cellInset ?? 0) + markerInset
        : id.startsWith('__parallel_')
        ? markerInset
        : 0,
    codeBox: id.startsWith('__parallel_') ? codeBox : null,
    codeTop: id.startsWith('__parallel_') ? codeTop : 0,
    codeBottom: id.startsWith('__parallel_') ? codeBottom : 0,
    line: id.startsWith('__parallel_') ? line : null,
    boxIndent: id.startsWith('__parallel_') ? boxIndent : 0,
    marginTop: id.startsWith('__parallel_') ? marginTop : tableMarginTop,
    marginBottom: id.startsWith('__parallel_')
        ? marginBottom
        : tableMarginBottom,
  );
}
