/// 完整章或长 TXT 小节的真实页数。window 为 -1 表示完整的普通章。
typedef ExactPageCount = ({
  int chapter,
  int window,
  int offset,
  int windows,
  int pages,
});

extension ExactPageCountWire on ExactPageCount {
  List<int> toWire() => [chapter, window, offset, windows, pages];
}

ExactPageCount decodeExactPageCount(List row) => (
  chapter: row[0] as int,
  window: row[1] as int,
  offset: row[2] as int,
  windows: row[3] as int,
  pages: row[4] as int,
);

/// 同一纸面下的零散结果。只有章内所有小节都已完成才作为完整章交付。
class ExactPageCounts {
  final chapters = <int, List<int>>{};
  final _windows = <int, Map<int, ExactPageCount>>{};

  bool add(ExactPageCount part) {
    if (chapters.containsKey(part.chapter)) return false;
    if (part.window < 0) {
      chapters[part.chapter] = [part.pages];
    } else {
      final sections = _windows.putIfAbsent(part.chapter, () => {});
      if (sections.containsKey(part.window)) return false;
      sections[part.window] = part;
      if (sections.length == part.windows) {
        _windows.remove(part.chapter);
        chapters[part.chapter] = [
          for (var i = 0; i < part.windows; i++) sections[i]!.pages,
        ];
      }
    }
    return true;
  }

  int? lookup(int chapter, int window, int offset, int windows) {
    final row = chapters[chapter];
    if (row != null && row.length == windows) return row[window];
    final part = _windows[chapter]?[window];
    return part?.offset == offset && part?.windows == windows
        ? part!.pages
        : null;
  }

  Iterable<ExactPageCount> get partialWindows sync* {
    for (final sections in _windows.values) {
      yield* sections.values;
    }
  }
}
