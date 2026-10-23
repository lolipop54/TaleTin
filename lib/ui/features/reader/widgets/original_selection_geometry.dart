part of 'original_host_controller.dart';

/// 原书选区几何：宿主页视口宽、正文区范围与选区矩形（都在宿主页视口坐标里）。
///
/// [content] 是正文区（不含上下信息行）在视口里的纵向范围：页首/页末判定、
/// 「手指推出正文区」都用它，免得把信息行当成正文的一部分。
class OriginalSelectionGeometry {
  const OriginalSelectionGeometry({
    required this.width,
    required this.content,
    required this.textTop,
    required this.textBottom,
    required this.rects,
    required this.leading,
    required this.trailing,
    required this.leadingHeight,
    required this.trailingHeight,
    this.pageFrom,
    this.pageTo,
    this.continuation,
    this.previousContinuation,
    this.continuationHeight = 0,
    this.previousContinuationHeight = 0,
  });

  /// 宿主页视口宽（CSS 像素）
  final double width;

  /// 正文区（不含上下信息行）的纵向范围；横向范围对多栏正文没有意义
  final Rect content;

  /// 本页第一行文字的上沿与最后一行文字的下沿（视口坐标）
  final double textTop;
  final double textBottom;

  /// 选区矩形（视口坐标）、它在排版的第几页（相对当前页，诊断用）
  /// 以及它是否落在当前页上（判定用，不看页序）
  final List<({int page, bool onPage, Rect rect})> rects;

  /// 首末字的手柄落点，与底色横带独立；混合字体会把底色切成不同高度的小块。
  final Offset? leading, trailing;
  final double leadingHeight, trailingHeight;

  /// 本页那一段选区的首/末文字在 DOM 上的位置（把范围夹在本页内用它）
  final Map<String, Object?>? pageFrom;
  final Map<String, Object?>? pageTo;

  /// 页末终点在下一页首字旁的可拖动落点，不扩选正文。
  final Offset? continuation;

  /// 页首起点在上一页末字旁的可拖动落点，不扩选正文。
  final Offset? previousContinuation;
  final double continuationHeight, previousContinuationHeight;

  /// 同章翻页只平移横坐标，先用已准备的几何接上新页，再由网页复核。
  OriginalSelectionGeometry shifted(int pages) {
    final delta = Offset(-pages * width, 0);
    return OriginalSelectionGeometry(
      width: width,
      content: content,
      textTop: textTop,
      textBottom: textBottom,
      leading: leading == null ? null : leading! + delta,
      trailing: trailing == null ? null : trailing! + delta,
      leadingHeight: leadingHeight,
      trailingHeight: trailingHeight,
      continuationHeight: continuationHeight,
      previousContinuationHeight: previousContinuationHeight,
      continuation: continuation == null ? null : continuation! + delta,
      previousContinuation: previousContinuation == null
          ? null
          : previousContinuation! + delta,
      rects: [
        for (final item in rects)
          (
            page: item.page - pages,
            onPage:
                item.rect.right + delta.dx > 1 &&
                item.rect.left + delta.dx < width - 1,
            rect: item.rect.shift(delta),
          ),
      ],
    );
  }
}
