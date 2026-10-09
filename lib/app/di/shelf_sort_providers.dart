import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/drift_shelf_sort_repository.dart';
import '../../domain/repositories/shelf_sort_repository.dart';
import 'app_providers.dart';

final shelfSortRepositoryProvider = Provider<ShelfSortRepository>(
  (ref) => DriftShelfSortRepository(ref.watch(appDatabaseProvider)),
);
