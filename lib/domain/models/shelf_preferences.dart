import 'shelf_sort.dart';

/// 书架的展示偏好：排序方式与网格／列表布局。
///
/// 两项都存在全局 preferences 里，启动时一起读出。书架第一帧就用保存的
/// 排序和布局显示，不会先闪一下默认网格再切到列表。
class ShelfPreferences {
  const ShelfPreferences({this.sort = ShelfSort.title, this.gridView = true});

  final ShelfSort sort;

  /// 是否使用网格布局；false 表示列表布局。
  final bool gridView;

  ShelfPreferences copyWith({ShelfSort? sort, bool? gridView}) =>
      ShelfPreferences(
        sort: sort ?? this.sort,
        gridView: gridView ?? this.gridView,
      );
}
