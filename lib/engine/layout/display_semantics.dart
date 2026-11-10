import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';

/// MathML 的注释是另一种编码，不是紧接在公式后的正文。只在存在主显示分支时
/// 隐藏备用分支；原文字、块号和 UTF-16 范围全部保留，供旧书位置继续使用。
class DisplaySemantics {
  DisplaySemantics(
    DisplaySourceIndex? source,
    int? block,
    int from,
    int length,
  ) {
    if (source == null || block == null) return;
    final index = _indexes[source] ??= _index(source);
    for (final e in index[block] ?? const <DisplayElement>[]) {
      final annotation = e.tag == 'annotation' || e.tag == 'annotation-xml';
      final parent = e.parent == null ? null : source.element(e.parent!);
      final alternate =
          annotation &&
          parent?.tag == 'semantics' &&
          parent!.children.any((id) {
            final tag = source.element(id)!.tag;
            return tag != 'annotation' && tag != 'annotation-xml';
          });
      if (!alternate && e.tag != 'mo') continue;
      final ranges = e.ranges.where((r) => r.block == block).toList();
      if (ranges.isEmpty) continue;
      // br 等显示边界本身可能没有 text-node 来源范围，但仍属于备用分支。
      // 一个元素在同一正文块内的首尾范围包含这些内部间隙，必须一起跳过。
      final start =
          (ranges.map((r) => r.start).reduce((a, b) => a < b ? a : b) - from)
              .clamp(0, length);
      final end =
          (ranges.map((r) => r.end).reduce((a, b) => a > b ? a : b) - from)
              .clamp(0, length);
      if (start < end) (alternate ? hidden : operators).add((start, end));
    }
  }
  final hidden = <(int, int)>[];
  final operators = <(int, int)>[];

  // 一章只建立一次范围索引；普通正文不逐块扫描整棵来源树。
  static final _indexes = Expando<Map<int, List<DisplayElement>>>();
  static Map<int, List<DisplayElement>> _index(DisplaySourceIndex source) {
    final result = <int, List<DisplayElement>>{};
    for (final e in source.elements.where(
      (e) =>
          e.tag == 'mo' || e.tag == 'annotation' || e.tag == 'annotation-xml',
    )) {
      for (final block in e.ranges.map((r) => r.block).toSet()) {
        (result[block] ??= []).add(e);
      }
    }
    return result;
  }

  List<TextRun> splitOperators(List<TextRun> runs) {
    if (operators.isEmpty) return runs;
    final result = <TextRun>[];
    var cursor = 0;
    for (final run in runs) {
      final end = cursor + run.text.length;
      final cuts = <int>{
        cursor,
        end,
        for (final (a, b) in operators) ...[
          a.clamp(cursor, end),
          b.clamp(cursor, end),
        ],
      }.toList()..sort();
      for (var i = 1; i < cuts.length; i++) {
        result.add(
          TextRun.fromJson({
            ...run.toJson(),
            'text': run.text.substring(cuts[i - 1] - cursor, cuts[i] - cursor),
          }),
        );
      }
      cursor = end;
    }
    return result;
  }

  bool operatorAt(int offset) =>
      operators.any((r) => r.$1 <= offset && offset < r.$2);
}
