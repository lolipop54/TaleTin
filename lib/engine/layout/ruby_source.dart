import '../../domain/models/display_source_index.dart';

/// 注音只改变显示位置。保留 rt/rp 原有字符，旧书的偏移无需迁移。
typedef RubyRange = ({
  int start,
  int baseEnd,
  int end,
  int labelStart,
  int labelEnd,
});

abstract final class RubySource {
  static final _byBlock = Expando<Map<int, List<RubyRange>>>();

  static List<RubyRange> of(DisplaySourceIndex? source, int? block) =>
      source == null || block == null
      ? const []
      : (_byBlock[source] ??= _index(source))[block] ?? const [];

  static Map<int, List<RubyRange>> _index(DisplaySourceIndex source) {
    final result = <int, List<RubyRange>>{};
    for (final ruby in source.elements.where((e) => e.tag == 'ruby')) {
      for (final block in ruby.ranges.map((r) => r.block).toSet()) {
        final ranges = ruby.ranges.where((r) => r.block == block);
        var start = ranges.first.start;
        int? baseEnd;
        for (final id in ruby.children) {
          final child = source.element(id)!;
          if (child.tag != 'rt' && child.tag != 'rp') continue;
          final text = child.ranges.where((r) => r.block == block);
          if (text.isEmpty) continue;
          if (child.tag == 'rp') {
            final annotations = result[block];
            final previous = annotations?.lastOrNull;
            if (text.first.start == start && previous?.end == start) {
              annotations![annotations.length - 1] = (
                start: previous!.start,
                baseEnd: previous.baseEnd,
                labelStart: previous.labelStart,
                labelEnd: previous.labelEnd,
                end: text.last.end,
              );
              start = text.last.end;
            } else {
              baseEnd ??= text.first.start;
            }
            continue;
          }
          final end = baseEnd ?? text.first.start;
          if (start < end) {
            (result[block] ??= []).add((
              start: start,
              baseEnd: end,
              end: text.last.end,
              labelStart: text.first.start,
              labelEnd: text.last.end,
            ));
          }
          start = text.last.end;
          baseEnd = null;
        }
      }
    }
    return result;
  }
}
