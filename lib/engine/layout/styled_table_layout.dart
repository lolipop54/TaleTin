part of 'table_layout.dart';

/// 有来源样式的表格直接使用书内的单元格几何。旧数据继续走基础表格规则。
List<MeasuredBlock>? _measureStyledTable(
  ContentTable table,
  Map<String, ContentBlock> blocks,
  LayoutOptions options,
  TableContainerLayout containers,
  StyleTable? styles,
  DisplayTree? tree,
  BlockMeasurementCache? cache,
  _DisplayTable display,
) {
  if (tree?.authoritative != true || styles == null) return null;
  final element = display.element?.element;
  if (element == null) return null;
  final tableStyle = styles[element.styleId ?? 0];
  final cellStyles = {
    for (final entry in display.cells.entries)
      entry.key: styles[entry.value.element.styleId ?? 0],
  };
  final rowStyles = [
    for (final row in display.rows) styles[row.element.styleId ?? 0],
  ];
  bool sizesText(ComputedStyle style) =>
      style.text.fontSize != null || style.text.lineHeight != null;
  final captions = display.element!.children
      .where(
        (n) =>
            n.element.role == 'caption' &&
            !tree!.hiddenElements.contains(n.element.id),
      )
      .toList();
  // 页内双列同样按阅读纸面断页。avoid-column 只约束 CSS 栏，不约束纸面。
  bool avoidsPage(String? value) => value == 'avoid' || value == 'avoid-page';
  final keptGroups = <int, int>{};
  var headerRows = 0;
  for (var i = 0; i < display.rows.length;) {
    final first = i;
    final parent = display.rows[i++].parent;
    while (i < display.rows.length && display.rows[i].parent == parent) {
      i++;
    }
    if (parent == null || parent == display.element) continue;
    final group = styles[parent.element.styleId ?? 0].block;
    // 已入库的样式保存作者声明。thead 的默认避断也适用于这些书。
    final avoid =
        group.breakInside ??
        TagDefaults.forTag(parent.element.tag)?['break-inside'];
    if (first == 0 &&
        parent.display == DisplaySpec.tableHeaderGroup &&
        avoidsPage(avoid)) {
      headerRows = i;
    }
    if (avoidsPage(avoid)) keptGroups[first] = i;
  }
  if (headerRows > 0) {
    for (var r = headerRows; r < rowStyles.length; r++) {
      final avoid = rowStyles[r].block.breakInside;
      if (avoidsPage(avoid)) {
        keptGroups.putIfAbsent(r, () => r + 1);
      }
    }
  }
  // 相邻行的两个声明约束的是同一个断点。与已有的行组范围有交集时，
  // 组首也要预留连接的行；仅仅首尾相接的两个独立行组仍可在组间分页。
  var firstKept = -1;
  const forced = {'page', 'left', 'right', 'recto', 'verso'};
  for (var i = 0; i < rowStyles.length; i++) {
    final after = rowStyles[i].block.breakAfter;
    if (i + 1 < rowStyles.length) {
      final before = rowStyles[i + 1].block.breakBefore;
      if (!forced.contains(after) &&
          !forced.contains(before) &&
          (avoidsPage(after) || avoidsPage(before))) {
        keptGroups[i] = math.max(keptGroups[i] ?? 0, i + 2);
      }
    }
    final end = keptGroups[i];
    if (end == null) continue;
    if (i < (keptGroups[firstKept] ?? 0)) {
      keptGroups[firstKept] = math.max(keptGroups[firstKept]!, end);
    } else {
      firstKept = i;
    }
  }
  final authored =
      keptGroups.isNotEmpty ||
      table.blockIds.isEmpty ||
      captions.isNotEmpty ||
      (tableStyle.block.float != null &&
          tableStyle.block.float != FloatSpec.none) ||
      table.cells.any((cell) => cell.rowSpan > 1) ||
      table.columnStyles?.isNotEmpty == true ||
      !tableStyle.box.isEmpty ||
      !tableStyle.table.isEmpty ||
      tableStyle.size.hasDimensions ||
      display.rows.any(
        (r) =>
            r.parent != null &&
            !styles[r.parent!.element.styleId ?? 0].box.isEmpty,
      ) ||
      rowStyles.any(
        (style) =>
            !style.box.isEmpty ||
            !style.size.isEmpty ||
            style.text.verticalAlign != null,
      ) ||
      cellStyles.values.any(
        (style) =>
            !style.box.isEmpty ||
            !style.size.isEmpty ||
            style.block.textAlign != null ||
            style.text.whiteSpace != null ||
            sizesText(style) ||
            style.text.verticalAlign != null,
      ) ||
      table.blockIds.any((id) {
        final block = blocks[id]!;
        return sizesText(styles[block.styleId ?? 0]) ||
            block.runs.any((run) => sizesText(styles[run.styleId ?? 0]));
      });
  if (!authored) return null;

  final available = math.max(
    1.0,
    options.contentWidth - containers.left - containers.right,
  );
  final tableContext = DisplayBoxLayout.context(tableStyle, options, available);
  final marginContext = DisplayBoxLayout.context(
    tableStyle,
    options,
    containers.marginReference ?? available,
    authorTableCell: true,
  );
  double wrapperMargin(Length? v) =>
      v == null || v.isAuto ? 0 : v.resolve(marginContext);
  final tableMarginTop = wrapperMargin(tableStyle.block.margin?.top);
  final tableMarginBottom = wrapperMargin(tableStyle.block.margin?.bottom);
  final rtl = tableStyle.table.direction == 'rtl';
  int physicalColumn(ContentTableCell cell) =>
      rtl ? table.columns - cell.column - cell.columnSpan : cell.column;
  final collapse = tableStyle.table.borderCollapse == 'collapse';
  final gap = collapse
      ? 0.0
      : math.max(
          0.0,
          tableStyle.table.borderSpacing?.resolve(tableContext) ?? 2,
        );

  final rowGap = collapse
      ? 0.0
      : tableStyle.table.borderSpacingY?.resolve(tableContext) ?? gap;

  LengthContext contextOf(ContentTableCell cell) => DisplayBoxLayout.context(
    cellStyles[cell]!,
    options,
    available,
    authorTableCell: true,
  );
  final boxes = [
    for (final cell in table.cells)
      resolveBlockBox(
        cellStyles[cell]!.box,
        contextOf(cell),
        collapsedCell: collapse,
        tableColor: cellStyles[cell]!.text.color?.argb,
      ),
  ];
  final hidden = [
    for (final cell in table.cells)
      collapse ? hiddenTableBorders(cellStyles[cell]!.box.border) : 0,
  ];
  final borderInsets = [for (final _ in table.cells) List.filled(4, 0.0)];
  final horizontalBorders = [
    for (final _ in table.cells) <TableHorizontalBorder>[],
  ];
  final verticalBorders = [
    for (final _ in table.cells) <TableVerticalBorder>[],
  ];
  final grid = CollapsedTableBorders(rtl: rtl);
  if (collapse) {
    _structuralBorders(grid, table, display, styles, options, available);
    for (var i = 0; i < table.cells.length; i++) {
      final cell = table.cells[i];
      grid.add(
        i,
        Rect.fromLTWH(
          physicalColumn(cell).toDouble(),
          cell.row.toDouble(),
          cell.columnSpan.toDouble(),
          cell.rowSpan.toDouble(),
        ),
        boxes[i],
        hidden[i],
      );
    }
    grid.resolve((horizontal, _, start, end, edge, cells) {
      for (final (:cell, :side) in cells) {
        borderInsets[cell][side] = math.max(
          borderInsets[cell][side],
          edge.width / 2,
        );
        if (horizontal) {
          horizontalBorders[cell].add((
            left: start,
            right: end,
            border: edge,
            top: side == 0,
          ));
        } else {
          verticalBorders[cell].add((
            top: start,
            bottom: end,
            border: edge,
            left: side == 3,
          ));
        }
      }
    });
  }
  // 合并模型的网格边界经过最外侧边线的中心。外侧的另一半占表宽，
  // 表自身的边线与格线共享；不能先扣表的整条线再扣格线，或完全漏扣。
  final tableFrame = containers.frames
      .where((f) => f.elementId == element.id)
      .firstOrNull;
  final tableBox = tableFrame?.box;
  var outerLeft = 0.0, outerRight = 0.0, outerTop = 0.0, outerBottom = 0.0;
  if (collapse) {
    for (final (i, cell) in table.cells.indexed) {
      if (cell.row == 0) outerTop = math.max(outerTop, borderInsets[i][0]);
      if (cell.row + cell.rowSpan == table.rows) {
        outerBottom = math.max(outerBottom, borderInsets[i][2]);
      }
      if (physicalColumn(cell) == 0) {
        outerLeft = math.max(outerLeft, borderInsets[i][3]);
      }
      if (physicalColumn(cell) + cell.columnSpan == table.columns) {
        outerRight = math.max(outerRight, borderInsets[i][1]);
      }
    }
  }
  final leftCorrection = collapse
      ? outerLeft - (tableBox?.insetLeft ?? 0)
      : 0.0;
  final rightCorrection = collapse
      ? outerRight - (tableBox?.insetRight ?? 0)
      : 0.0;
  final gridTop =
      containers.top + (collapse ? outerTop - (tableBox?.insetTop ?? 0) : 0);
  final gridBottom =
      containers.bottom +
      (collapse ? outerBottom - (tableBox?.insetBottom ?? 0) : 0);
  BlockMeasurer cellMeasurer(double innerWidth, double innerHeight) =>
      BlockMeasurer(
        LayoutOptions(
          settings: options.settings.copyWith(indent: false, lineHeight: 1.4),
          contentSize: Size(innerWidth, math.max(1, innerHeight)),
          textScaler: options.textScaler,
          cssDark: options.cssDark,
          publicationFonts: options.publicationFonts,
        ),
        styleTable: styles,
        displayTree: tree,
        flatNest: true,
        authorTableCell: true,
        cache: cache,
      );
  final sideNodes = captions
      .where(
        (n) => const {
          'left',
          'right',
        }.contains(styles[n.element.styleId ?? 0].table.captionSide),
      )
      .toList();
  final topBottomNodes = captions.where((n) => !sideNodes.contains(n)).toList();
  // 侧置表题与网格共享当前栏宽，遇到长题注允许其在侧栏内换行。
  double sideWidth(String side) {
    final nodes = sideNodes
        .where((n) => styles[n.element.styleId ?? 0].table.captionSide == side)
        .toList();
    if (nodes.isEmpty) return 0;
    final desired = _captionMinimum(
      nodes,
      tree!,
      styles,
      options,
      blocks,
      available,
      cellMeasurer(available, options.contentHeight),
    );
    return desired.clamp(
      1.0,
      math.max(1.0, available / (sideNodes.length + 1)),
    );
  }

  final sideLeft = sideWidth('left'), sideRight = sideWidth('right');
  final gridAvailable =
      available - leftCorrection - rightCorrection - sideLeft - sideRight;
  final width = math.max(1.0, gridAvailable - (table.columns + 1) * gap);
  final cellInsets = [
    for (final (i, box) in boxes.indexed)
      _cellContentInsets(box, collapse ? borderInsets[i] : null),
  ];
  final fixed =
      tableStyle.table.tableLayout == 'fixed' &&
      tableStyle.size.width?.isAuto == false;
  final outerWidth = collapse
      ? outerLeft + outerRight
      : (tableBox?.insetLeft ?? 0) + (tableBox?.insetRight ?? 0);
  late final probe = cellMeasurer(width, options.contentHeight);
  late final minWidth = math.max(
    _tableLength(tableStyle.size.minWidth, tableContext),
    topBottomNodes.isEmpty
        ? 0.0
        : _captionMinimum(
                topBottomNodes,
                tree!,
                styles,
                options,
                blocks,
                available,
                probe,
              ) -
              outerWidth,
  );
  final widths = fixed
      ? _fixedColumnWidths(
          table,
          cellStyles,
          styles,
          options,
          width,
          boxes,
          cellInsets,
          gap: gap,
        )
      : _autoColumnWidths(
          table,
          cellStyles,
          styles,
          options,
          width,
          boxes,
          cellInsets,
          gap: gap,
          shrink: tableStyle.size.width?.isAuto ?? true,
          minimum: minWidth - (table.columns + 1) * gap,
          blocks: blocks,
          tree: tree!,
          probe: probe,
        );
  // 等自然列宽算出后再决定是否缩小。小宽度的竖题表允许靠内容撑开，
  // 直到碰到父栏的留白；作者声明可横向滚动的表则使用自己的窗口宽度。
  final parentWidth = containers.marginReference ?? available;
  final columnBudget = math.max(
    1.0,
    parentWidth -
        wrapperMargin(tableStyle.block.margin?.left) -
        wrapperMargin(tableStyle.block.margin?.right) -
        outerWidth -
        sideLeft -
        sideRight -
        (table.columns + 1) * gap,
  );
  final scrollable =
      tableStyle.box.overflow == 'auto' || tableStyle.box.overflow == 'scroll';
  _fitColumnsToPage(
    widths,
    scrollable ? math.min(width, columnBudget) : columnBudget,
    table,
    cellInsets,
    boxes,
    options,
  );
  final usedWidth =
      widths.fold(0.0, (a, b) => a + b) + (table.columns + 1) * gap;
  final spareWidth = gridAvailable - usedWidth;
  final shift = DisplayBoxLayout.tableWidthOffset(
    tableStyle,
    options,
    containers.marginReference ?? available,
    tableBox,
    initialWidth: available,
    finalWidth: available - spareWidth,
  );
  final wrapperWidth = usedWidth + outerWidth;
  final tableLeft =
      containers.left + sideLeft + shift - (tableBox?.insetLeft ?? 0);
  final captionBoxes = _measureCaptions(
    topBottomNodes,
    tree!,
    styles,
    options,
    blocks,
    wrapperWidth,
    cellMeasurer,
  );
  final lateralBoxes = [
    for (final node in sideNodes)
      ..._measureCaptions(
        [node],
        tree,
        styles,
        options,
        blocks,
        styles[node.element.styleId ?? 0].table.captionSide == 'left'
            ? sideLeft
            : sideRight,
        cellMeasurer,
      ),
  ];
  final beforeCaption = _sum(
    captionBoxes.where((c) => !c.bottom).map((c) => c.extent),
  );
  final afterCaption = _sum(
    captionBoxes.where((c) => c.bottom).map((c) => c.extent),
  );
  final frames = [
    for (final f in containers.frames)
      if (f.elementId == element.id)
        ContainerBoxFrame(
          elementId: f.elementId,
          box: collapse ? _tableBackdrop(f.box) : f.box,
          first: f.first,
          last: f.last,
          left: f.left + shift + sideLeft,
          width: f.width - spareWidth - sideLeft - sideRight,
          top: f.top + beforeCaption,
          bottom: f.bottom + afterCaption,
          height: f.height,
        )
      else
        f,
  ];
  final lefts = [containers.left + sideLeft + leftCorrection + shift + gap];
  for (final columnWidth in rtl ? widths.reversed : widths) {
    lefts.add(lefts.last + columnWidth + gap);
  }
  double widthOf(ContentTableCell cell) =>
      lefts[physicalColumn(cell) + cell.columnSpan] -
      lefts[physicalColumn(cell)] -
      gap;
  final rows = _TableRows(table.rows);
  final gridHeight = containers.contentHeight == null
      ? null
      : math.max(0.0, containers.contentHeight! - rowGap * (table.rows + 1));
  for (final (row, style) in rowStyles.take(table.rows).indexed) {
    rows.applyHeight(
      row,
      style.size,
      DisplayBoxLayout.context(style, options, width),
    );
  }
  final characters = _TableCharacterAlignment();
  final measurements =
      <
        ContentTableCell,
        ({
          List<_CellItem> items,
          BlockBox? box,
          double height,
          double width,
          double minimumHeight,
          double? baseline,
          String align,
          EdgeInsets padding,
          List<TableHorizontalBorder> horizontalBorders,
        })
      >{};
  for (var i = 0; i < table.cells.length; i++) {
    final cell = table.cells[i];
    final style = cellStyles[cell]!;
    final context = contextOf(cell);
    final box = boxes[i];
    final padding = cellInsets[i];
    final vertical = padding.vertical;
    final innerWidth = math.max(1.0, widthOf(cell) - padding.horizontal);
    final items = <_CellItem>[];
    var height = 0.0;
    var trailing = const VerticalMargin.zero();
    final inlineMeasurer = cellMeasurer(
      innerWidth,
      options.contentHeight - vertical,
    );
    for (final id in cell.blocks) {
      final index = tree.blockIndexById[id]!;
      if (tree.hiddenBlocks.contains(index)) continue;
      final edges = _cellListEdges(tree, index, styles, options, innerWidth);
      final itemWidth = math.max(1.0, innerWidth - edges.horizontal);
      final block =
          (edges.horizontal == 0
                  ? inlineMeasurer
                  : cellMeasurer(itemWidth, options.contentHeight - vertical))
              .measure(blocks[id]!);
      if (style.block.textAlign == TextAlignSpec.char) {
        characters.measure(cell, block, itemWidth, options.textScaler);
      }
      // td/th 的 margin 不占格内空间；格内段落的上下边距参与行高。
      final ownsCell = tree.source!.ownerOfBlock(index)?.role == 'cell';
      final before = VerticalMargin.of(edges.top)
          .join(VerticalMargin.of(ownsCell ? 0.0 : block.marginTop));
      height += trailing.join(before).extent;
      items.add((
        block: block,
        width: itemWidth,
        left: edges.left,
        top: height,
      ));
      height += block.height;
      trailing = VerticalMargin.of(edges.bottom)
          .join(VerticalMargin.of(ownsCell ? 0.0 : block.marginBottom));
    }
    height += trailing.extent;
    final cellHeight = BoxSizeResolver.heightOf(
      context,
      style.size,
      box,
      parentHeight: null,
      verticalEdges: vertical,
    );
    final align = _cellVerticalAlign(display.cells[cell]!, styles);
    final baseline = align == 'baseline'
        ? _cellBaseline(items, height, options.textScaler) + padding.top
        : null;
    if (cell.rowSpan == 1) {
      rows.applyHeight(cell.row, style.size, context, cell: true);
    }
    measurements[cell] = (
      align: align,
      baseline: baseline,
      items: items,
      box:
          !collapse &&
              style.table.emptyCells == 'hide' &&
              !_hasCellContent(display.cells[cell]!, tree, styles, items)
          ? null
          : box,
      padding: padding,
      horizontalBorders: [
        for (final edge in horizontalBorders[i])
          (
            left: lefts[edge.left.toInt()],
            right: lefts[edge.right.toInt()],
            border: edge.border,
            top: edge.top,
          ),
      ],
      height: height,
      width: innerWidth,
      minimumHeight: math.max(height, cellHeight.use(0)) + vertical,
    );
  }
  for (final cell in table.cells) {
    final measure = measurements[cell]!;
    rows.measureCell(
      cell,
      measure.minimumHeight,
      measure.height + measure.padding.vertical,
      measure.baseline,
    );
  }
  rows.distribute(rowGap, gridHeight);
  // 行组高度约束组内所有行的合计，只分配一次额外空间。
  for (var i = 0; i < display.rows.length;) {
    final first = i;
    final parent = display.rows[i++].parent;
    while (i < display.rows.length && display.rows[i].parent == parent) {
      i++;
    }
    if (parent == null || parent == display.element) continue;
    final group = styles[parent.element.styleId ?? 0];
    final height = group.size.height;
    if (height == null ||
        height.isAuto ||
        height is PercentLength && gridHeight == null) {
      continue;
    }
    final context = DisplayBoxLayout.context(group, options, width);
    final target = height.resolve(
      context.copyWith(reference: gridHeight ?? width),
    );
    rows._grow(
      first,
      i - first,
      target - (i - first - 1) * rowGap,
      span: false,
    );
  }
  final tops = [beforeCaption + gridTop + rowGap];
  for (final height in rows.heights) {
    tops.add(tops.last + height + rowGap);
  }

  final breakRows = <TableBreakRow>[
    if (keptGroups.isNotEmpty || table.cells.any((c) => c.rowSpan > 1))
      for (var r = 0; r < rows.heights.length; r++)
        (
          top: tops[r],
          bottom: tops[r + 1] - rowGap,
          avoidUntil: keptGroups[r] == null
              ? null
              : tops[keptGroups[r]!] - rowGap,
        ),
  ];
  final id = table.blockIds.firstOrNull ?? '__grid_${element.id}';
  final TableHeaderBand? headerBand =
      headerRows > 0 &&
          table.cells.any((c) => c.row == 0) &&
          table.cells.any((c) => c.row >= headerRows)
      ? (
          top: tops.first,
          bottom: tops[headerRows] - rowGap,
          bodyTop: tops[headerRows],
          bodyEnd: tops.last - rowGap,
        )
      : null;
  final result = <MeasuredBlock>[];
  // 页尾留白由首块携带，底部表题已包含网格与表题之间的格距。
  final tail = afterCaption == 0
      ? gridBottom + rowGap
      : captionBoxes.where((c) => c.bottom).last.marginBottom;
  void addCaptions(Iterable<_TableCaption> entries, double origin, double x) {
    var y = origin;
    for (final caption in entries) {
      y += caption.marginTop;
      final bounds = Rect.fromLTWH(
        x + caption.left,
        y,
        caption.width,
        caption.height,
      );
      for (final item in caption.items) {
        result.add(
          item.block.inTable(
            id: id,
            bounds: bounds,
            top: y + item.top,
            unit: 0,
            header: false,
            width: item.width,
            containerBoxes: frames,
            breakRows: result.isEmpty ? breakRows : const [],
            headerBand: result.isEmpty ? headerBand : null,
            tableBottom: tail,
            tableMarginTop: tableMarginTop,
            tableMarginBottom: tableMarginBottom,
            cellInset: item.left,
            cellBox: caption.box,
            authorStyle: true,
          ),
        );
      }
      y += caption.height + caption.marginBottom;
    }
  }

  addCaptions(captionBoxes.where((c) => !c.bottom), 0, tableLeft);
  addCaptions(
    lateralBoxes.where((c) => c.side == 'left'),
    beforeCaption,
    tableLeft - sideLeft,
  );
  addCaptions(
    lateralBoxes.where((c) => c.side == 'right'),
    beforeCaption,
    tableLeft + wrapperWidth,
  );
  final backdrops = List.generate(table.rows, (_) => <TableBackdrop>[]);
  void addBackdrop(ComputedStyle style, int first, int end) {
    if (style.box.background == null) return;
    final box = resolveBlockBox(
      style.box,
      DisplayBoxLayout.context(style, options, width),
    );
    if (box == null) return;
    final area = Rect.fromLTRB(
      lefts.first,
      tops[first],
      lefts.last - gap,
      tops[end] - rowGap,
    );
    for (var row = first; row < end; row++) {
      backdrops[row].add((area: area, box: box));
    }
  }

  for (var i = 0; i < display.rows.length;) {
    final first = i, parent = display.rows[i++].parent;
    while (i < display.rows.length && display.rows[i].parent == parent) {
      i++;
    }
    if (parent != null && parent != display.element) {
      addBackdrop(styles[parent.element.styleId ?? 0], first, i);
    }
    for (var r = first; r < i; r++) {
      addBackdrop(rowStyles[r], r, r + 1);
    }
  }
  for (final (index, cell) in table.cells.indexed) {
    final measured = measurements[cell]!;
    final box = measured.box;
    final bounds = Rect.fromLTRB(
      lefts[physicalColumn(cell)],
      tops[cell.row],
      lefts[physicalColumn(cell) + cell.columnSpan] - gap,
      tops[cell.row + cell.rowSpan] - rowGap,
    );

    final spare = math.max(
      0,
      bounds.height - measured.height - measured.padding.vertical,
    );
    final y =
        bounds.top +
        measured.padding.top +
        switch (measured.align) {
          'bottom' => spare,
          'middle' => spare / 2,
          'baseline' => rows.baselines[cell.row] - measured.baseline!,
          _ => 0.0,
        };
    final contents = measured.items.isEmpty
        ? [
            (
              block: MeasuredBlock(
                blockId:
                    cell.blocks.firstOrNull ??
                    (tree.emptyGrids.containsKey(element.id)
                        ? tree.anchorBlockId(element.anchor)
                        : '__empty_${id}_${cell.row}_${cell.column}'),
                kind: BlockKind.paragraph,
                isDecoration: true,
              ),
              width: measured.width,
              left: 0.0,
              top: 0.0,
            ),
          ]
        : measured.items;
    for (final item in contents) {
      final block = item.block;
      result.add(
        block.inTable(
          id: id,
          bounds: bounds,
          top: y + item.top,
          breakRows: result.isEmpty ? breakRows : const [],
          headerBand: result.isEmpty ? headerBand : null,
          contentBottom: y + measured.height + measured.padding.bottom,
          unit: 0,
          header: cell.header,
          width: item.width,
          containerBoxes: frames,
          tableBottom: tail,
          tableMarginTop: tableMarginTop,
          tableMarginBottom: tableMarginBottom,
          cellInset:
              measured.padding.left +
              item.left +
              characters.inset(cell, block, item.width),
          cellBox: box,
          backdrops: backdrops[cell.row],
          collapsedBorders: collapse,
          horizontalBorders: measured.horizontalBorders,
          verticalBorders: [
            for (final edge in verticalBorders[index])
              (
                top: tops[edge.top.toInt()],
                bottom: tops[edge.bottom.toInt()],
                border: edge.border,
                left: edge.left,
              ),
          ],
          authorStyle: true,
        ),
      );
    }
  }
  final sideHeight = math.max(
    _sum(lateralBoxes.where((c) => c.side == 'left').map((c) => c.extent)),
    _sum(lateralBoxes.where((c) => c.side == 'right').map((c) => c.extent)),
  );
  addCaptions(
    captionBoxes.where((c) => c.bottom),
    math.max(tops.last + gridBottom, beforeCaption + sideHeight),
    tableLeft,
  );
  return result;
}
