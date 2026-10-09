import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/drift_book_group_repository.dart';
import '../../domain/models/book_group.dart';
import '../../domain/repositories/book_group_repository.dart';
import 'app_providers.dart';

final bookGroupRepositoryProvider = Provider<BookGroupRepository>(
  (ref) => DriftBookGroupRepository(ref.watch(appDatabaseProvider)),
);
final bookGroupsProvider = StreamProvider<List<BookGroup>>(
  (ref) => ref.watch(bookGroupRepositoryProvider).watch(),
);
