part of 'block_measure.dart';

extension MathBlockMeasurement on BlockMeasurer {
  /// 长段滚动分批时不能切进公式内部，否则两批都会退回普通文字绘制。
  int formulaSafeEnd(ContentBlock block, int end) {
    final tree = displayTree ?? formulaTree;
    final index = tree?.blockIndexById[block.id];
    final source = tree?.source;
    if (index == null || source == null || tree!.formulas.isEmpty) return end;
    for (final e in source.elements) {
      if (!tree.formulas.containsKey(e.id)) continue;
      for (final range in e.ranges.where((r) => r.block == index)) {
        if (range.start < end && end < range.end) end = range.end;
      }
    }
    return end;
  }

  bool _startsDisplayFormula(ContentBlock block, int offset) {
    final tree = displayTree ?? formulaTree;
    final index = tree?.blockIndexById[block.id];
    final source = tree?.source;
    if (source == null || index == null) return false;
    // 长章测量每一段时只查所属块，避免反复扫全章元素找公式。
    final starts = _displayFormulaStarts ??= () {
      final result = <int, Set<int>>{};
      for (final element in source.elements) {
        final xml = element.math;
        if (xml == null || !_displayFormula(xml)) continue;
        for (final range in element.ranges) {
          (result[range.block] ??= {}).add(range.start);
        }
      }
      return result;
    }();
    return starts[index]?.contains(offset) ?? false;
  }

  /// 转换只发生在异步准备阶段。树同时供普通正文、引用和表格单元格测量使用。
  Future<void> prepareMath(ChapterContent content) =>
      _mathPreparation ??= _prepareFormulas(content);

  Future<void> _prepareFormulas(ChapterContent content) async {
    final source = displayTree?.source, renderer = MathTypesetting.renderer;
    if (source == null || renderer == null) return;
    for (final e in source.elements.where((e) => e.math != null)) {
      var parent = e.parent;
      var nested = false;
      while (parent != null) {
        final p = source.element(parent)!;
        if (p.math != null) {
          nested = true;
          break;
        }
        parent = p.parent;
      }
      if (nested) continue;
      final blockIndex = e.ranges.firstOrNull?.block ?? e.anchor;
      if (blockIndex >= content.blocks.length) continue;
      try {
        displayTree!.formulas[e.id] = await renderer.render(e.math!);
      } on Object catch (error, stack) {
        // 单个公式无效时仍显示其原文，不把整章变成错误页面。
        AppErrors.report(error, stack, operation: '数学公式转换失败', notify: false);
      }
    }
  }

  double _formulaEm(ContentBlock block, int? styleId) {
    final style = ResolvedRunStyle.fromStyle(
      styleTable?[styleId ?? 0] ?? ComputedStyle.empty,
    );
    final font = options
        .textStyleFor(
          block.kind,
          level: block.level,
          sizeScale: style.sizeScale,
          hasFontSize: style.hasFontSize,
        )
        .fontSize!;
    return options.textScaler.scale(font);
  }

  List<_InlineSpec> _formulasFor(
    ContentBlock block,
    int sourceOffset,
    int prefix,
    double width,
    double height,
  ) {
    final tree = displayTree ?? formulaTree, source = tree?.source;
    final index = tree?.blockIndexById[block.id];
    if (source == null || index == null || tree!.formulas.isEmpty) {
      return const [];
    }
    final result = <_InlineSpec>[];
    for (final e in source.elements.where(
      (e) => tree.formulas.containsKey(e.id),
    )) {
      final ranges = e.ranges.where((r) => r.block == index).toList();
      if (ranges.isEmpty) continue;
      final from = ranges.map((r) => r.start).reduce(math.min) - sourceOffset;
      final end = ranges.map((r) => r.end).reduce(math.max) - sourceOffset;
      if (from < 0 || end > block.runLength || from >= end) continue;
      final f = tree.formulas[e.id]!;
      final em = _formulaEm(block, e.styleId);
      final scale = math.min(em, math.min(width / f.width, height / f.height));
      result.add(
        _InlineSpec(
          offset: from + prefix,
          size: Size(f.width * scale, f.height * scale),
          resourcePath: f.resource,
          blockDisplay: _displayFormula(e.math!),
          formula: FormulaGeometry(
            end: end + prefix,
            baseline: f.baseline * scale,
          ),
        ),
      );
    }
    return result;
  }

  bool _displayFormula(String xml) =>
      RegExp(r'''\bdisplay\s*=\s*["']block["']''').hasMatch(xml);
}
