import '../models/shelf_preferences.dart';
import '../models/shelf_sort.dart';

/// 书架展示偏好的读写：排序方式和网格／列表布局。
abstract interface class ShelfPreferencesRepository {
  /// 一次读出两项偏好；没有保存过时返回默认值。
  Future<ShelfPreferences> load();

  Future<void> saveSort(ShelfSort sort);

  Future<void> saveGridView(bool gridView);
}
