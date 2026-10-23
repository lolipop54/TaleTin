import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/concurrency/background_compute.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/services/toc_presentation.dart';
import '../../../../domain/services/toc_rows.dart';

typedef TocTreeInput = (List<TocNode>, List<Chapter>);
final _tree = FutureProvider.autoDispose.family<List<TocVolume>, TocTreeInput>(
  (ref, input) => backgroundCompute(_build, input),
);
final tocVolumesProvider = Provider.autoDispose
    .family<AsyncValue<List<TocVolume>>, TocTreeInput>((ref, input) {
      if (!largeToc(input.$1, input.$2.length, backgroundListThreshold)) {
        return AsyncData(_build(input));
      }
      return ref.watch(_tree(input));
    });
List<TocVolume> _build(TocTreeInput input) =>
    buildTocVolumes(input.$1, input.$2);

typedef TocRowsInput = (List<TocVolume>, Set<int>, String, bool);
typedef TocRowsResult = ({List<TocRow> rows, List<int> visible, int count});
final _rows = FutureProvider.autoDispose.family<TocRowsResult, TocRowsInput>(
  (ref, input) => backgroundCompute(_flatten, input),
);
final tocRowsProvider = Provider.autoDispose
    .family<AsyncValue<TocRowsResult>, TocRowsInput>((ref, input) {
      var count = 0;
      for (final volume in input.$1) {
        count += volume.chapters.length + 1;
        if (count >= backgroundListThreshold) break;
      }
      if (count < backgroundListThreshold) return AsyncData(_flatten(input));
      return ref.watch(_rows(input));
    });
TocRowsResult _flatten(TocRowsInput input) {
  final (volumes, expanded, query, descending) = input;
  final searching = query.isNotEmpty;
  final visible = [
    for (var i = 0; i < volumes.length; i++)
      if (!searching || volumes[i].matches(query)) i,
  ];
  return (
    rows: flattenTocRows(
      volumes,
      visible,
      expanded,
      query,
      searching: searching,
      descending: descending,
    ),
    visible: visible,
    count: volumes.fold<int>(0, (n, v) => n + v.chapters.length),
  );
}
