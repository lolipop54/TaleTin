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
final pdfFixedViewModeProvider = readingControlsProvider.select(
  (state) => state.value?.pdfFixedViewMode ?? false,
);

class ReadingControlsNotifier extends AsyncNotifier<ReadingControls> {
  Future<void> _writing = Future.value();
  @override
  Future<ReadingControls> build() =>
      ref.watch(readingControlsRepositoryProvider).load();
  Future<void> change({
    bool? awake,
    bool? keys,
    bool? swipeUpToExit,
    bool? statusBar,
    bool? navigationBar,
    bool? imageViewing,
    bool? pdfFixedViewMode,
  }) {
    final next = _writing.then((_) async {
      final repo = ref.read(readingControlsRepositoryProvider);
      final old = await repo.load();
      final value = ReadingControls(
        keepAwake: awake ?? old.keepAwake,
        volumeKeys: keys ?? old.volumeKeys,
        swipeUpToExit: swipeUpToExit ?? old.swipeUpToExit,
        statusBar: statusBar ?? old.statusBar,
        navigationBar: navigationBar ?? old.navigationBar,
        imageViewing: imageViewing ?? old.imageViewing,
        pdfFixedViewMode: pdfFixedViewMode ?? old.pdfFixedViewMode,
      );
      await repo.save(value);
      if (ref.mounted) state = AsyncData(value);
    });
    _writing = next.catchError((Object _) {});
    return next;
  }
}
