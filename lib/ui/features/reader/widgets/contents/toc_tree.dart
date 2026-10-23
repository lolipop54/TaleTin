import '../../../../../domain/models/book_document.dart';
import '../../../../../domain/services/toc_entry_index.dart';
import '../../view_models/reader_session_view_model.dart';
import '../../../../../domain/services/toc_presentation.dart';
export '../../../../../domain/services/toc_presentation.dart';

/// 同一 spine 章节下有多个目录标题时，用当前位置之前最近的标题。
String? currentTocTitleOf(ReaderSession? session, List<TocVolume> volumes) {
  if (session == null) return null;
  final titles = [
    for (final volume in volumes)
      for (final entry in volume.chapters)
        if (entry.chapterId == session.chapter.id) entry.title,
  ];
  if (titles.length <= 1) return null;
  final titleSet = titles.toSet();
  final txtHeadings = {
    for (final volume in volumes)
      for (final entry in volume.chapters)
        if (entry.chapterId == session.chapter.id &&
            entry.anchorId?.startsWith('gt-txt:') == true)
          entry.anchorId!.substring(7),
  };
  // 旧 TXT 补充目录按块 ID 定位，不能把普通正文中的同名文字当章题。
  bool isTitle(BlockKind kind, String id) =>
      kind == BlockKind.heading || txtHeadings.contains(id);
  final layout = session.layout;
  if (!session.isOriginal && layout != null) {
    for (final fragment
        in layout.page(session.pageIndex)?.fragments ?? const []) {
      final block = fragment.block;
      if (!isTitle(block.kind, block.blockId)) continue;
      final title = block.runs.map((run) => run.text).join().trim();
      if (titleSet.contains(title)) return title;
      final shortTitle = tocHeadingWithoutNumber(title);
      if (titleSet.contains(shortTitle)) return shortTitle;
    }
  }
  final content = session.content;
  final blockId = session.currentAnchor?.blockId;
  if (content == null || blockId == null) return titles.first;
  final target = content.blocks.indexWhere((block) => block.id == blockId);
  if (target < 0) return titles.first;
  for (var i = target; i >= 0; i--) {
    final block = content.blocks[i];
    if (!isTitle(block.kind, block.id)) continue;
    final title = block.runs.map((run) => run.text).join().trim();
    if (titleSet.contains(title)) return title;
    final shortTitle = tocHeadingWithoutNumber(title);
    if (titleSet.contains(shortTitle)) return shortTitle;
  }
  return titles.first;
}
