import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/local_book_files_provider.dart';
import '../../../../app/di/app_providers.dart';
import 'import_view_model.dart';
import '../../../../domain/services/local_book_files.dart';

enum LocalFilesMode { smart, folders }

enum LocalFilesSort {
  time('按时间倒序排序'), name('按文件名称排序'), size('按文件大小排序');
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

class LocalFilesState {
  const LocalFilesState({
    this.mode = LocalFilesMode.smart,
    this.path,
    this.entries = const [],
    this.selected = const {},
    this.busy = false,
    this.message,
    this.query = '',
    this.sortOrder,
    this.visited = 0,
    this.imported = const {},
    this.scanning = false,
  });
  final LocalFilesMode mode;
  final String? path;
  final List<LocalBookEntry> entries;
  final Map<String, LocalBookEntry> selected;
  final bool busy;
  final String? message;
  final String query;
  final LocalFilesSort? sortOrder;
  LocalFilesSort get sort => sortOrder ?? (mode == LocalFilesMode.smart
      ? LocalFilesSort.time : LocalFilesSort.name);
  final int visited;
  final Set<String> imported;
  final bool scanning;
  List<LocalBookEntry> get visible => entries
      .where(
        (e) =>
            e.name.toLowerCase().contains(query.toLowerCase()),
      )
      .toList();
  LocalFilesState copy({
    LocalFilesMode? mode,
    String? path,
    bool clearPath = false,
    List<LocalBookEntry>? entries,
    Map<String, LocalBookEntry>? selected,
    bool? busy,
    String? message,
    String? query,
    LocalFilesSort? sortOrder,
    int? visited,
    Set<String>? imported,
    bool? scanning,
  }) => LocalFilesState(
    mode: mode ?? this.mode,
    path: clearPath ? null : path ?? this.path,
    entries: entries ?? this.entries,
    selected: selected ?? this.selected,
    busy: busy ?? this.busy,
    message: message,
    query: query ?? this.query,
    sortOrder: sortOrder ?? this.sortOrder,
    visited: visited ?? this.visited,
    imported: imported ?? this.imported,
    scanning: scanning ?? this.scanning,
  );
}

final localFilesProvider =
    NotifierProvider.autoDispose<LocalFilesViewModel, LocalFilesState>(
      LocalFilesViewModel.new,
    );

class LocalFilesViewModel extends Notifier<LocalFilesState> {
  int _request = 0;
  List<LocalBookEntry> _roots = [];
  List<LocalBookEntry> _smartEntries = [];
  Set<String> _smartImported = {};
  @override
  LocalFilesState build() {
    ref.onDispose(() => _request++);
    return const LocalFilesState(busy: true);
  }

  void filter({String? query}) => state = state.copy(query: query);
  void sortBy(LocalFilesSort sort) {
    final entries = [...state.entries]..sort((a, b) => compareLocalFiles(a, b, sort));
    state = state.copy(entries: entries, sortOrder: sort);
  }
  void toggle(LocalBookEntry entry) {
    if (state.busy || state.imported.contains(entry.path) || _queued(entry)) return;
    final selected = {...state.selected};
    if (selected.remove(entry.path) == null) selected[entry.path] = entry;
    state = state.copy(selected: selected);
  }

  bool get allSelected {
    final files = state.visible.where((e) => !e.directory &&
      !state.imported.contains(e.path) && !_queued(e));
    return files.isNotEmpty && files.every((e) => state.selected.containsKey(e.path));
  }

  void toggleAll() {
    if (state.busy) return;
    final files = state.visible.where((e) => !e.directory &&
      !state.imported.contains(e.path) && !_queued(e)).toList();
    final all = files.every((e) => state.selected.containsKey(e.path));
    final selected = {...state.selected};
    for (final e in files) {
      if (all) {
        selected.remove(e.path);
      } else {
        selected[e.path] = e;
      }
    }
    state = state.copy(selected: selected);
  }

  void cancel() {
    _request++;
    state = state.copy(busy: false, message: '已取消，保留上次列表');
  }

  /// 查询期间只更新进度，不清空旧目录或旧扫描结果。
  Future<void> load(LocalFilesMode mode, {String? path}) async {
    final request = ++_request;
    final files = ref.read(localBookFilesProvider);
    // 切到智能导入立即显示该模式；目录内部导航仍保留旧目录直到读完。
    final switchToSmart = mode == LocalFilesMode.smart && state.mode != mode;
    state = state.copy(busy: true, visited: 0, scanning: mode == LocalFilesMode.smart,
      mode: switchToSmart ? mode : null, clearPath: switchToSmart,
      entries: switchToSmart ? _smartEntries : null,
      imported: switchToSmart ? _smartImported : null);
    try {
      if (!await files.hasAccess() && !await files.requestAccess()) {
        if (request == _request) {
          state = state.copy(busy: false, message: '未授权，无法读取手机文件');
        }
        return;
      }
      if (request != _request) return;
      _roots = await files.roots();
      if (request != _request) return;
      final entries = <LocalBookEntry>[];
      var skipped = 0;
      if (mode == LocalFilesMode.folders) {
        entries.addAll(path == null ? _roots : await files.list(path));
      } else {
        final pending = _roots.map((e) => e.path).toList();
        final seen = <String>{};
        while (pending.isNotEmpty && request == _request) {
          final directory = pending.removeLast();
          if (!seen.add(directory)) continue;
          try {
            for (final entry in await files.list(directory, counts: false)) {
              if (entry.directory) {
                pending.add(entry.path);
              } else {
                entries.add(entry);
              }
            }
          } catch (_) {
            skipped++;
          }
          if (request == _request && seen.length % 20 == 0) {
            state = state.copy(busy: true, visited: seen.length);
          }
        }
        // 授权在扫描中途被撤销时不能把不完整结果当成扫描成功。
        if (request == _request && !await files.hasAccess()) {
          throw StateError('文件访问权限已关闭');
        }
      }
      if (request != _request) return;
      final sort = state.copy(mode: mode).sort;
      entries.sort((a, b) => compareLocalFiles(a, b, sort));
      final imported = await _findImported(entries, request);
      if (request != _request) return;
      if (mode == LocalFilesMode.smart) {
        _smartEntries = entries;
        _smartImported = imported;
      }
      state = state.copy(
        mode: mode,
        path: path,
        clearPath: path == null,
        entries: entries,
        imported: imported,
        selected: {...state.selected}..removeWhere((path, _) => imported.contains(path)),
        busy: false,
        message: skipped > 0 ? '扫描完成，$skipped 个目录无法读取，已跳过' : null,
      );
    } catch (_) {
      if (request == _request) {
        state = state.copy(busy: false, message: '读取失败，请检查文件权限后重试');
      }
    }
  }

  bool _queued(LocalBookEntry entry) => ref.read(importProvider).items.any(
    (item) => item.key == entry.document.uri && !item.stage.isFinished);

  Future<Set<String>> _findImported(List<LocalBookEntry> entries, int request) async {
    final books = await ref.read(libraryBooksProvider.future);
    if (request != _request) return {};
    return ref.read(localImportMatcherProvider).findImported(entries, books,
      cancelled: () => request != _request);
  }

  /// 导入期间返回文件页时，书架变化后重新匹配，整体发布已导入状态。
  Future<void> refreshImported() async {
    if (state.busy) return;
    final request = ++_request;
    state = state.copy(busy: true, scanning: false);
    final imported = await _findImported(state.entries, request);
    if (request != _request) return;
    state = state.copy(busy: false, imported: imported,
      selected: {...state.selected}..removeWhere((path, _) => imported.contains(path)));
  }

  Future<void> up() async {
    final path = state.path;
    if (path == null) return;
    await load(
      LocalFilesMode.folders,
      path: _roots.any((e) => e.path == path)
          ? null
          : path.substring(0, path.lastIndexOf('/')),
    );
  }

  Future<void> deleteSelected() async {
    if (state.busy) return;
    final files = ref.read(localBookFilesProvider);
    final request = ++_request;
    state = state.copy(busy: true);
    final removed = <String>{};
    for (final path in state.selected.keys) {
      if (request != _request) return;
      try {
        await files.delete(path);
        removed.add(path);
      } catch (_) {
        /* 保留失败项供重试。 */
      }
    }
    if (request != _request) return;
    final remaining = {...state.selected}
      ..removeWhere((key, _) => removed.contains(key));
    state = state.copy(
      busy: false,
      entries: state.entries.where((e) => !removed.contains(e.path)).toList(),
      selected: remaining,
      message: remaining.isEmpty
          ? '已删除 ${removed.length} 个源文件'
          : '${remaining.length} 个文件删除失败，仍保留选中',
    );
  }
}
