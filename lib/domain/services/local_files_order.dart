import 'local_book_files.dart';

enum LocalFilesSort {
  time('按时间倒序排序'),
  name('按文件名称排序'),
  size('按文件大小排序');

  const LocalFilesSort(this.label);
  final String label;
}

/// 文件夹始终在前；同值时按名称和路径固定次序，避免刷新后跳动。
int compareLocalFiles(LocalBookEntry a, LocalBookEntry b, LocalFilesSort sort) {
  if (a.directory != b.directory) return a.directory ? -1 : 1;
  if (!a.directory) {
    final primary = switch (sort) {
      LocalFilesSort.time => b.modified.compareTo(a.modified),
      LocalFilesSort.size => b.size.compareTo(a.size),
      LocalFilesSort.name => a.initial.compareTo(b.initial),
    };
    if (primary != 0) return primary;
  }
  final name = a.sortName.toLowerCase().compareTo(b.sortName.toLowerCase());
  return name != 0 ? name : a.path.compareTo(b.path);
}
