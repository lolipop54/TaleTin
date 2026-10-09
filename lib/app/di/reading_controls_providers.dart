import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories/reading_controls_repository.dart';
import '../../data/repositories/drift_reading_controls_repository.dart';
import 'app_providers.dart';

final readingControlsRepositoryProvider = Provider<ReadingControlsRepository>(
  (ref) => DriftReadingControlsRepository(ref.watch(appDatabaseProvider)),
);
final readingControlsProvider =
    AsyncNotifierProvider<ReadingControlsNotifier, ReadingControls>(
      ReadingControlsNotifier.new,
    );

class ReadingControlsNotifier extends AsyncNotifier<ReadingControls> {
  Future<void> _writing = Future.value();
  @override
  Future<ReadingControls> build() =>
      ref.watch(readingControlsRepositoryProvider).load();
  Future<void> change({
    bool? awake,
    bool? keys,
    bool? statusBar,
    bool? navigationBar,
  }) {
    final next = _writing.then((_) async {
      final repo = ref.read(readingControlsRepositoryProvider);
      final old = await repo.load();
      final value = ReadingControls(
        keepAwake: awake ?? old.keepAwake,
        volumeKeys: keys ?? old.volumeKeys,
        statusBar: statusBar ?? old.statusBar,
        navigationBar: navigationBar ?? old.navigationBar,
      );
      await repo.save(value);
      if (ref.mounted) state = AsyncData(value);
    });
    _writing = next.catchError((Object _) {});
    return next;
  }
}
