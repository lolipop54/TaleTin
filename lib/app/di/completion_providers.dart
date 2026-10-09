import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/drift_book_completion_repository.dart';
import '../../domain/models/book_completion.dart';
import '../../domain/repositories/book_completion_repository.dart';
import 'app_providers.dart';

final bookCompletionRepositoryProvider = Provider<BookCompletionRepository>(
  (ref) => DriftBookCompletionRepository(ref.watch(appDatabaseProvider)));
final bookCompletionsProvider = StreamProvider<List<BookCompletion>>(
  (ref) => ref.watch(bookCompletionRepositoryProvider).watch());
