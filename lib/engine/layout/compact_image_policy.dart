import 'display_tree.dart';
import 'measured_block.dart';
import '../../domain/models/book_document.dart';

/// 分页按当前栏的正常显示尺寸计算，最多等比缩小 40%。
const minimumCompactImageScale = .6;

final _detailImageLabel = RegExp(
  r'地图|地圖|示意[图圖]|流程[图圖]|结构图|結構圖|线路图|線路圖|电路图|電路圖|'
  r'\b(?:map|diagram|schematic|flowchart)\b',
  caseSensitive: false,
);

bool canCompactIllustration(MeasuredBlock image, DisplayTree? tree) {
  if (image.kind != BlockKind.image ||
      image.imageSize == null ||
      image.isDecoration ||
      image.paperArtwork ||
      image.pageTop != null ||
      image.imageFit?.mode == 'none' ||
      tree?.coverBlockId == image.blockId ||
      tree?.openingArtwork?.id == image.blockId ||
      tree?.portraits.containsKey(image.blockId) == true ||
      _detailImageLabel.hasMatch(image.alt ?? '')) {
    return false;
  }
  final caption = tree?.galleryCaptions[image.blockId];
  return caption == null ||
      !caption.runs.any((run) => _detailImageLabel.hasMatch(run.text));
}
