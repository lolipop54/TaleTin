import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/drift_shelf_preferences_repository.dart';
import '../../domain/repositories/shelf_preferences_repository.dart';
import 'app_providers.dart';

final shelfPreferencesRepositoryProvider = Provider<ShelfPreferencesRepository>(
  (ref) => DriftShelfPreferencesRepository(ref.watch(appDatabaseProvider)),
);
