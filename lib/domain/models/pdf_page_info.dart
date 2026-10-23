import 'book_document.dart';
import 'locator.dart';

/// 原页与标准正文的对应关系。矩形使用旋转后页面的左上角坐标，范围为0～1。
/// 它属于持久正文资料，不能随页面位图缓存删除。
class PdfPageInfo {
  const PdfPageInfo({
    required this.index,
    required this.width,
    required this.height,
    required this.blocks,
    this.pendingPictures = false,
  });
  final int index;
  final double width, height;
  final Map<String, List<double>> blocks;

  /// 整页背景中的插图只在电子书模式实际读到本页时分析，避免拖慢导入。
  final bool pendingPictures;

  double yOf(Locator anchor) => anchor.pdfY ?? blocks[anchor.blockId]?[1] ?? 0;

  Locator anchorAt(
    ChapterContent content,
    String bookId,
    String chapterId,
    double y, {
    int contentVersion = kContentVersion,
  }) {
    var block = content.blocks.first;
    var distance = double.infinity;
    for (final candidate in content.blocks) {
      final box = blocks[candidate.id];
      if (box == null) continue;
      final next = y < box[1]
          ? box[1] - y
          : y > box[1] + box[3]
          ? y - box[1] - box[3]
          : 0.0;
      if (next < distance) {
        block = candidate;
        distance = next;
      }
    }
    final text = block.runs.map((r) => r.text).join();
    return Locator(
      bookId: bookId,
      contentVersion: contentVersion,
      chapterId: chapterId,
      blockId: block.id,
      utf16Offset: 0,
      exact: text.length > 32 ? text.substring(0, 32) : text,
      imageResource: block.resourcePath,
      pdfY: y.clamp(0.0, 1.0),
    );
  }

  Map<String, Object?> toJson() => {
    'index': index,
    'width': width,
    'height': height,
    'blocks': blocks,
    if (pendingPictures) 'pendingPictures': true,
  };
  factory PdfPageInfo.fromJson(Map<String, dynamic> json) => PdfPageInfo(
    index: json['index'] as int,
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    pendingPictures: json['pendingPictures'] == true,
    blocks: (json['blocks'] as Map).map(
      (k, v) => MapEntry(
        k as String,
        (v as List).map((n) => (n as num).toDouble()).toList(),
      ),
    ),
  );
}
