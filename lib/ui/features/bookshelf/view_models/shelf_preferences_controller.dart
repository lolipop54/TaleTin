import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/shelf_preferences_providers.dart';
import '../../../../domain/models/shelf_preferences.dart';
import '../../../../domain/models/shelf_sort.dart';

/// 书架的排序与布局偏好。
///
/// 首次读取完成才展示书架；保存成功才发布新值，失败保留原设置。
class ShelfPreferencesController extends AsyncNotifier<ShelfPreferences> {
  @override
  Future<ShelfPreferences> build() =>
      ref.watch(shelfPreferencesRepositoryProvider).load();

  Future<void> saveSort(ShelfSort sort) async {
    await ref.read(shelfPreferencesRepositoryProvider).saveSort(sort);
    _publish((current) => current.copyWith(sort: sort));
  }

  Future<void> saveGridView(bool gridView) async {
    await ref.read(shelfPreferencesRepositoryProvider).saveGridView(gridView);
    _publish((current) => current.copyWith(gridView: gridView));
  }

  /// 保存成功后把新值并入当前偏好；写入失败时不会走到这里。
  void _publish(ShelfPreferences Function(ShelfPreferences) update) {
    final current = state.value;
    if (ref.mounted && current != null) state = AsyncData(update(current));
  }
}

final shelfPreferencesProvider =
    AsyncNotifierProvider<ShelfPreferencesController, ShelfPreferences>(
      ShelfPreferencesController.new,
    );
