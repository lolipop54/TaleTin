import '../../core/concurrency/background_compute.dart';
import '../../domain/services/local_book_files.dart';
import '../../domain/services/local_files_order.dart';

typedef LocalFilePresentation = ({
  List<LocalBookEntry> entries,
  List<LocalBookEntry> visible,
});
Future<LocalFilePresentation> prepareLocalFiles(
  List<LocalBookEntry> entries,
  LocalFilesSort sort,
  String query,
) => backgroundCompute(localFilePresentation, (
  entries,
  sort,
  query,
), enabled: entries.length >= backgroundListThreshold);

LocalFilePresentation localFilePresentation(
  (List<LocalBookEntry>, LocalFilesSort, String) input,
) {
  final (entries, sort, query) = input;
  final names = {
    for (final entry in entries) entry: entry.sortName.toLowerCase(),
  };
  final initials = {for (final entry in entries) entry: entry.initial};
  final sorted = [...entries]
    ..sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      if (!a.directory) {
        final order = switch (sort) {
          LocalFilesSort.time => b.modified.compareTo(a.modified),
          LocalFilesSort.size => b.size.compareTo(a.size),
          LocalFilesSort.name => initials[a]!.compareTo(initials[b]!),
        };
        if (order != 0) return order;
      }
      final name = names[a]!.compareTo(names[b]!);
      return name != 0 ? name : a.path.compareTo(b.path);
    });
  final q = query.toLowerCase();
  return (
    entries: sorted,
    visible: q.isEmpty
        ? sorted
        : sorted.where((e) => e.name.toLowerCase().contains(q)).toList(),
  );
}
