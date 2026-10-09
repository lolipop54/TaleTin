/// 逻辑章节索引（离线听书实现计划 5、6.2）。
///
/// 「逻辑章节」是目录里一个**可定位正文条目**的范围：从一个条目起点到下一个
/// 条目起点，最后一个到正文末尾。它可能只占一个正文文件的一小块，也可能跨文件
/// ——一个 XHTML 里装着上百章时，逻辑章和正文文件根本不是一回事。
///
/// 这个索引**不读正文**：只用目录和章节清单排出顺序，具体位置交给调用方按需给出
/// （实现计划 6.2：映射先为当前资源准备）。这样两千章的书也能立刻建出索引，
/// 后台换章再按当前文件解析锚点。
library;

import '../models/book_document.dart';

/// 一个逻辑章节条目。
///
/// [id] 是稳定标识：有锚点时是「正文文件#锚点」，没有锚点时就是正文文件 ID，
/// 因此同名的不同锚点各自独立，相同目标的重复条目会合并（实现计划 6.2）。
class LogicalChapter {
  const LogicalChapter({
    required this.id,
    required this.title,
    required this.chapterId,
    this.fragment,
    this.isPreamble = false,
  });

  final String id;
  final String title;

  /// 起点所在的正文文件
  final String chapterId;

  /// 目录里的原始锚点；null 表示从这一章的开头起
  final String? fragment;

  /// 是否是「目录第一条之前的正文」那一段（版权页、卷首等，不能漏读）
  final bool isPreamble;

  @override
  bool operator ==(Object other) => other is LogicalChapter && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LogicalChapter($id·$title)';
}

/// 条目在书里的线性位置：章序 + 章内块序 + 块内偏移。
///
/// 由调用方按需给出。同一个正文文件内的条目要用真实块序与偏移，
/// 还没解析的文件用「章序 + 0」也够用：跨文件比较只用到章序。
class ChapterPosition implements Comparable<ChapterPosition> {
  const ChapterPosition({
    required this.chapterOrdinal,
    this.blockIndex = 0,
    this.utf16Offset = 0,
  });

  /// 章节在书里的阅读顺序（`Chapter.ordinal`）
  final int chapterOrdinal;
  final int blockIndex;
  final int utf16Offset;

  @override
  int compareTo(ChapterPosition other) {
    if (chapterOrdinal != other.chapterOrdinal) {
      return chapterOrdinal - other.chapterOrdinal;
    }
    if (blockIndex != other.blockIndex) return blockIndex - other.blockIndex;
    return utf16Offset - other.utf16Offset;
  }

  bool operator <=(ChapterPosition other) => compareTo(other) <= 0;

  @override
  String toString() =>
      'ChapterPosition($chapterOrdinal/$blockIndex@$utf16Offset)';
}

/// 某个条目起点在书里的位置；调用方按需解析（解析不了就给粗位置）。
typedef LogicalChapterPosition = ChapterPosition Function(LogicalChapter entry);

/// 一本书的逻辑章节索引。
class LogicalChapterIndex {
  const LogicalChapterIndex._(this.chapters);

  /// 按阅读顺序排好的条目
  final List<LogicalChapter> chapters;

  bool get isEmpty => chapters.isEmpty;

  int get length => chapters.length;

  /// 按目录建立索引。
  ///
  /// 规则（实现计划 6.2）：
  /// - 没有目标的分组节点（卷、纯分类）不进索引；
  /// - 相同目标合并为一条，同名但锚点不同各自保留；
  /// - 第一条目录之前的正文补一段起始范围，避免漏读；
  /// - 没有可用目录（TXT、目录尚未恢复的旧书）时按正文文件顺序，每章一条。
  factory LogicalChapterIndex.build({
    required List<Chapter> bookChapters,
    required List<TocNode> toc,
  }) {
    final entries = <LogicalChapter>[];
    final seenTargets = <String>{};

    void visit(TocNode node) {
      final chapterId = node.chapterId;
      final title = node.title.trim();
      if (chapterId != null && title.isNotEmpty) {
        final fragment = node.fragment?.trim();
        final target =
            fragment == null || fragment.isEmpty ? chapterId : '$chapterId#$fragment';
        if (seenTargets.add(target)) {
          entries.add(
            LogicalChapter(
              id: target,
              title: title,
              chapterId: chapterId,
              fragment: fragment,
            ),
          );
        }
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final node in toc) {
      visit(node);
    }

    if (entries.isEmpty) {
      return LogicalChapterIndex._([
        for (final chapter in bookChapters)
          LogicalChapter(
            id: chapter.id,
            title: chapter.title,
            chapterId: chapter.id,
          ),
      ]);
    }

    // 目录第一条之前的正文（或其所在文件的头部）单独成一段
    final first = entries.first;
    final firstChapter = bookChapters.isEmpty ? null : bookChapters.first;
    final needsPreamble = firstChapter != null &&
        (firstChapter.id != first.chapterId || first.fragment != null);
    return LogicalChapterIndex._([
      if (needsPreamble)
        LogicalChapter(
          id: 'preamble',
          title: firstChapter.title,
          chapterId: firstChapter.id,
          isPreamble: true,
        ),
      ...entries,
    ]);
  }

  /// [entry] 在索引里的下标；不在索引里返回 -1。
  int indexOf(LogicalChapter entry) => chapters.indexOf(entry);

  /// 下一条；到末尾返回 null（首尾不越界，也不循环）。
  LogicalChapter? nextOf(LogicalChapter entry) {
    final index = indexOf(entry);
    if (index < 0 || index + 1 >= chapters.length) return null;
    return chapters[index + 1];
  }

  /// 上一条；到开头返回 null。
  LogicalChapter? previousOf(LogicalChapter entry) {
    final index = indexOf(entry);
    if (index <= 0) return null;
    return chapters[index - 1];
  }

  /// 当前位置落在哪一条上。
  ///
  /// [positionOf] 给出各条目的起点位置：解析不了的文件返回粗位置即可，
  /// 只要章序对，跨文件的先后就正确。[current] 在这些条目之前时返回第一条。
  LogicalChapter locate({
    required ChapterPosition current,
    required LogicalChapterPosition positionOf,
  }) {
    var hit = 0;
    for (var i = 0; i < chapters.length; i++) {
      if (positionOf(chapters[i]) <= current) hit = i;
    }
    return chapters[hit];
  }

  /// 从下标 [from] 起（含）往后找第一条 [readable] 为真的条目。
  ///
  /// 纯图片章、空白范围就靠它跳过。只往后迭代一趟，到末尾返回 null——
  /// 不递归地无限找下一章（实现计划 6.2）。
  LogicalChapter? nextReadable(
    int from, {
    required bool Function(LogicalChapter entry) readable,
  }) {
    for (var i = from < 0 ? 0 : from; i < chapters.length; i++) {
      if (readable(chapters[i])) return chapters[i];
    }
    return null;
  }

  @override
  String toString() => 'LogicalChapterIndex(${chapters.length}条)';
}
