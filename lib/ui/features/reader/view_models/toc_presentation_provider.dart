import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/concurrency/background_compute.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/services/toc_presentation.dart';
import '../../../../domain/services/toc_rows.dart';
import '../../../../domain/services/txt_chapter_sections.dart';
import '../../../../domain/models/book.dart';
import '../../../../app/di/app_providers.dart';
import 'reader_session_view_model.dart';

final readerTxtSectionsProvider = FutureProvider.autoDispose
    .family<Map<String, List<TxtTocSection>>, String>((ref, bookId) {
      final session = ref.watch(
        readerSessionProvider(
          bookId,
        ).select((state) => (state.value?.book.format, state.value?.chapters)),
      );
      if (session.$1 != BookFormat.txt) return const {};
      final chapters = [
        for (final chapter in session.$2!)
          if (chapter.textLength >= kLongTxtChapterLength) chapter,
      ];
      if (chapters.isEmpty) return const {};
      return ref
          .read(chapterContentRepositoryProvider)
          .txtTocSections(bookId, chapters);
    });

typedef TocTreeInput = (
  List<TocNode>,
  List<Chapter>,
  Map<String, List<TxtTocSection>>,
);
final _tree = FutureProvider.autoDispose.family<List<TocVolume>, TocTreeInput>(
  (ref, input) => backgroundCompute(_build, input),
);
final tocVolumesProvider = Provider.autoDispose
    .family<AsyncValue<List<TocVolume>>, TocTreeInput>((ref, input) {
      var count = input.$2.length;
      for (final sections in input.$3.values) {
        count += sections.length;
      }
      if (!largeToc(input.$1, count, backgroundListThreshold)) {
        return AsyncData(_build(input));
      }
      return ref.watch(_tree(input));
    });
List<TocVolume> _build(TocTreeInput input) =>
    buildTocVolumes(input.$1, input.$2, txtSections: input.$3);

// 展开集合为 null 时，由搜索结果决定默认开合；大目录仍在后台一起准备。
typedef TocRowsInput = (List<TocVolume>, Set<int>?, String, bool, Set<String>?);
typedef TocRowsResult = ({
  List<TocRow> rows,
  List<int> visible,
  Set<int> expanded,
  Set<String> expandedSections,
  int count,
});
final _rows = FutureProvider.autoDispose.family<TocRowsResult, TocRowsInput>(
  (ref, input) => backgroundCompute(_flatten, input),
);
final tocRowsProvider = Provider.autoDispose
    .family<AsyncValue<TocRowsResult>, TocRowsInput>((ref, input) {
      var count = 0;
      for (final volume in input.$1) {
        count += volume.chapters.length + 1;
        for (final chapter in volume.chapters) {
          count += chapter.sections.length;
          if (count >= backgroundListThreshold) break;
        }
        if (count >= backgroundListThreshold) break;
      }
      if (count < backgroundListThreshold) return AsyncData(_flatten(input));
      return ref.watch(_rows(input));
    });
TocRowsResult _flatten(TocRowsInput input) {
  final (volumes, expanded, query, descending, expandedSections) = input;
  final searching = query.isNotEmpty;
  final visible = [
    for (var i = 0; i < volumes.length; i++)
      if (!searching || volumes[i].matches(query)) i,
  ];
  final resolvedExpanded =
      expanded ??
      {
        for (final index in visible)
          if (volumes[index].chapters.any((entry) => entry.matches(query)))
            index,
      };
  final resolvedSections =
      expandedSections ??
      {
        for (final index in visible)
          for (final entry in volumes[index].chapters)
            if (entry.sections.any((section) => section.matches(query)))
              entry.chapterId,
      };
  return (
    rows: flattenTocRows(
      volumes,
      visible,
      resolvedExpanded,
      query,
      searching: searching,
      descending: descending,
      expandedSections: resolvedSections,
    ),
    visible: visible,
    expanded: resolvedExpanded,
    expandedSections: resolvedSections,
    count: volumes.fold<int>(0, (n, v) => n + v.chapters.length),
  );
}
