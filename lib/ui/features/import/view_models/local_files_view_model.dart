import 'package:taletin/core/diagnostics/app_errors.dart';

import 'dart:async';

import '../../../../data/services/local_files_compute.dart';
import '../../../../data/services/local_file_scan_cache.dart';
import '../../../../domain/services/local_files_order.dart';
export '../../../../domain/services/local_files_order.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/local_book_files_provider.dart';
import '../../../../app/di/app_providers.dart';
import '../../../../app/di/imported_font_providers.dart';
import 'import_view_model.dart';
import '../../../../domain/services/local_book_files.dart';

enum LocalFilesMode { smart, folders }

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
    this.visibleEntries,
    this.needsRescan = false,
    this.scanIncomplete = false,
    this.accessDenied = false,
  });
  final LocalFilesMode mode;
  final String? path;
  final List<LocalBookEntry> entries;
  final Map<String, LocalBookEntry> selected;
  final bool busy;
  final String? message;
  final String query;
  final LocalFilesSort? sortOrder;
  LocalFilesSort get sort =>
      sortOrder ??
      (mode == LocalFilesMode.smart
          ? LocalFilesSort.time
          : LocalFilesSort.name);
  final int visited;
  final Set<String> imported;
  final bool scanning;
  final List<LocalBookEntry>? visibleEntries;
  final bool needsRescan, scanIncomplete, accessDenied;
  List<LocalBookEntry> get visible =>
      visibleEntries ??
      entries
          .where((e) => e.name.toLowerCase().contains(query.toLowerCase()))
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
    List<LocalBookEntry>? visibleEntries,
    bool? needsRescan,
    bool? scanIncomplete,
    bool? accessDenied,
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
    needsRescan: needsRescan ?? this.needsRescan,
    scanIncomplete: scanIncomplete ?? this.scanIncomplete,
    accessDenied: accessDenied ?? this.accessDenied,
    visibleEntries:
        visibleEntries ??
        (entries == null && query == null ? this.visibleEntries : null),
  );
}

final localFilesProvider =
    NotifierProvider.autoDispose<LocalFilesViewModel, LocalFilesState>(
      LocalFilesViewModel.new,
    );

// 两种用途的扫描、选择与缓存分别保存，返回书籍导入时不会混入字体结果。
final localFontFilesProvider =
    NotifierProvider.autoDispose<LocalFilesViewModel, LocalFilesState>(
      () => LocalFilesViewModel(LocalFilePurpose.fonts),
    );

class LocalFilesViewModel extends Notifier<LocalFilesState> {
  LocalFilesViewModel([this.purpose = LocalFilePurpose.books]);
  final LocalFilePurpose purpose;
  int _request = 0, _presentation = 0;
  List<LocalBookEntry> _roots = [];
  bool _checking = false;
  LocalFileScanCache get _cache =>
      ref.read(localFileScanCacheProvider(purpose));
  @override
  LocalFilesState build() {
    ref.onDispose(() {
      _request++;
      _presentation++;
    });
    return const LocalFilesState(busy: true);
  }

  void filter({String? query}) {
    state = state.copy(query: query, visibleEntries: state.visible);
    _refreshPresentation();
  }

  void sortBy(LocalFilesSort sort) {
    state = state.copy(sortOrder: sort, visibleEntries: state.visible);
    _refreshPresentation();
  }

  void _refreshPresentation() {
    final revision = ++_presentation;
    final entries = state.entries, query = state.query, sort = state.sort;
    void publish(LocalFilePresentation result) {
      if (ref.mounted &&
          revision == _presentation &&
          identical(entries, state.entries)) {
        state = state.copy(
          entries: result.entries,
          visibleEntries: result.visible,
        );
      }
    }

    if (entries.length < 256) {
      publish(localFilePresentation((entries, sort, query)));
    } else {
      unawaited(
        prepareLocalFiles(entries, sort, query).then(publish).catchError((
          Object e,
          StackTrace stack,
        ) {
          if (ref.mounted && revision == _presentation) {
            AppErrors.report(e, stack, operation: '整理本地文件失败');
          }
        }),
      );
    }
  }

  void toggle(LocalBookEntry entry) {
    if (state.busy ||
        state.accessDenied ||
        state.imported.contains(entry.path) ||
        _queued(entry)) {
      return;
    }
    final selected = {...state.selected};
    if (selected.remove(entry.path) == null) selected[entry.path] = entry;
    state = state.copy(selected: selected);
  }

  bool get allSelected {
    final files = state.visible.where(
      (e) => !e.directory && !state.imported.contains(e.path) && !_queued(e),
    );
    return files.isNotEmpty &&
        files.every((e) => state.selected.containsKey(e.path));
  }

  void toggleAll() {
    if (state.busy || state.accessDenied) return;
    final files = state.visible
        .where(
          (e) =>
              !e.directory && !state.imported.contains(e.path) && !_queued(e),
        )
        .toList();
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
    _presentation++;
    state = state.copy(busy: false, scanning: false, message: '已取消，保留上次列表');
  }

  /// 查询期间只更新进度，不清空旧目录或旧扫描结果。
  Future<void> load(
    LocalFilesMode mode, {
    String? path,
    bool rescan = false,
  }) async {
    final request = ++_request;
    final files = ref.read(localBookFilesProvider);
    final cache = _cache;
    final cached = cache.snapshot;
    final scanning = mode == LocalFilesMode.smart && (rescan || cached == null);
    // 使刷新前已开始的变化检查失效，但不删除上一份可用结果。
    if (scanning) cache.revision++;
    // 切到智能导入立即显示该模式；目录内部导航仍保留旧目录直到读完。
    final switchToSmart = scanning && state.mode != mode;
    state = state.copy(
      busy: true,
      visited: 0,
      scanning: scanning,
      mode: switchToSmart ? mode : null,
      clearPath: switchToSmart,
      entries: switchToSmart ? cached?.entries ?? [] : null,
      imported: switchToSmart ? {} : null,
    );
    try {
      if (!await files.hasAccess() && !await files.requestAccess()) {
        if (request == _request) {
          cache.uncertain = true;
          state = state.copy(
            busy: false,
            scanning: false,
            accessDenied: true,
            message: '未授权，无法读取手机文件',
          );
        }
        return;
      }
      if (request != _request) return;
      _roots = await files.roots();
      if (request != _request) return;
      var entries = <LocalBookEntry>[];
      LocalFileScanSnapshot? scanned;
      if (mode == LocalFilesMode.folders) {
        entries.addAll(
          path == null
              ? _roots
              : await files.list(path, extensions: purpose.extensions),
        );
      } else if (!scanning) {
        entries.addAll(cached!.entries);
      } else {
        scanned = await scanLocalFiles(
          files,
          purpose.extensions,
          _roots,
          previous: cached,
          cancelled: () => request != _request,
          onProgress: (visited) {
            if (request == _request) state = state.copy(visited: visited);
          },
        );
        if (scanned == null) return;
        entries.addAll(scanned.entries);
      }
      if (request != _request) return;
      entries.removeWhere(
        (e) => !e.directory && !purpose.extensions.contains(e.extension),
      );
      final imported = await _findImported(entries, request);
      if (request != _request) return;
      late LocalFilePresentation prepared;
      while (true) {
        final sort = state.copy(mode: mode).sort, query = state.query;
        prepared = await prepareLocalFiles(entries, sort, query);
        if (request != _request) return;
        if (sort == state.copy(mode: mode).sort && query == state.query) break;
      }
      _presentation++;
      entries = prepared.entries;
      if (!await files.hasAccess()) throw StateError('文件访问权限已关闭');
      if (request != _request) return;
      if (scanned != null) {
        cache.publish(
          LocalFileScanSnapshot(
            entries: entries,
            directories: scanned.directories,
            roots: scanned.roots,
            indexStamp: scanned.indexStamp,
            unreadable: scanned.unreadable,
            changedDuringScan: scanned.changedDuringScan,
          ),
        );
      }
      final byPath = {for (final e in entries) e.path: e};
      state = state.copy(
        mode: mode,
        path: path,
        clearPath: path == null,
        entries: entries,
        visibleEntries: prepared.visible,
        imported: imported,
        selected: {
          for (final e in state.selected.values)
            if (!imported.contains(e.path) &&
                !_queued(byPath[e.path] ?? e) &&
                (mode != LocalFilesMode.smart || byPath.containsKey(e.path)))
              e.path: byPath[e.path] ?? e,
        },
        busy: false,
        scanning: false,
        accessDenied: false,
        needsRescan: cache.changed,
        scanIncomplete: cache.uncertain,
        message: scanned != null && scanned.unreadable.isNotEmpty
            ? '${scanned.unreadable.length} 个目录暂时无法读取，保留已有记录'
            : null,
      );
      if (mode == LocalFilesMode.smart && !scanning) {
        unawaited(checkForChanges());
      }
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '扫描本地文件失败');
      if (request == _request) {
        cache.uncertain = true;
        state = state.copy(
          busy: false,
          scanning: false,
          scanIncomplete: true,
          message: '读取失败，请检查文件权限后重试',
        );
      }
    }
  }

  bool _queued(LocalBookEntry entry) =>
      purpose == LocalFilePurpose.books &&
      ref
          .read(importProvider)
          .items
          .any(
            (item) => item.key == entry.document.uri && !item.stage.isFinished,
          );

  /// 每次进入及从后台回来时检查；短时间重复请求合并，检查不锁住列表。
  Future<void> checkForChanges({bool force = false}) async {
    if (_checking || state.busy) return;
    final cache = _cache, snapshot = _cache.snapshot;
    if (snapshot == null) return;
    if (!force &&
        cache.checkedAt != null &&
        DateTime.now().difference(cache.checkedAt!) <
            const Duration(seconds: 3)) {
      return;
    }
    final request = _request, revision = cache.revision;
    bool cancelled() =>
        !ref.mounted || request != _request || revision != cache.revision;
    _checking = true;
    try {
      final files = ref.read(localBookFilesProvider);
      if (!await files.hasAccess()) {
        if (!cancelled()) {
          cache.uncertain = true;
          state = state.copy(
            accessDenied: true,
            scanIncomplete: true,
            message: '文件访问权限已关闭，请恢复权限后重新扫描',
          );
        }
        return;
      }
      if (cancelled()) return;
      final result = await checkLocalFileChanges(
        files,
        purpose.extensions,
        snapshot,
        cancelled: cancelled,
      );
      if (cancelled()) return;
      cache.changed |= result.changed;
      cache.uncertain |= result.uncertain;
      cache.checkedAt = DateTime.now();
      state = state.copy(
        needsRescan: cache.changed,
        scanIncomplete: cache.uncertain,
        accessDenied: false,
      );
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '检查本地文件变化失败');
      if (!cancelled()) {
        cache.uncertain = true;
        state = state.copy(scanIncomplete: true);
      }
    } finally {
      _checking = false;
    }
  }

  /// 缓存只供展示。提交前重新读取选中文件的属性，部分失效不阻断有效文件。
  Future<List<LocalBookEntry>> validateForImport(
    List<LocalBookEntry> entries,
  ) async {
    if (state.busy || entries.isEmpty) return [];
    final request = ++_request;
    final files = ref.read(localBookFilesProvider), cache = _cache;
    state = state.copy(busy: true, scanning: false);
    try {
      if (!await files.hasAccess()) {
        if (request == _request) {
          cache.uncertain = true;
          state = state.copy(
            busy: false,
            accessDenied: true,
            scanIncomplete: true,
            message: '文件访问权限已关闭，请恢复权限后重新扫描',
          );
        }
        return [];
      }
      final current = <String, LocalBookEntry>{};
      final missing = <String>{}, unavailable = <String>{};
      for (var at = 0; at < entries.length; at += 256) {
        if (request != _request) return [];
        final result = await files.inspect(
          entries.skip(at).take(256).map((e) => e.path).toList(),
        );
        for (final e in result.entries) {
          if (!e.directory && purpose.extensions.contains(e.extension)) {
            current[e.path] = e;
          } else {
            missing.add(e.path);
          }
        }
        missing.addAll(result.missing);
        unavailable.addAll(result.unavailable);
      }
      if (!await files.hasAccess()) throw StateError('文件访问权限已关闭');
      if (request != _request) return [];
      cache.remove(missing);
      final failed = entries.length - current.length;
      if (failed > 0 || entries.any((e) => current[e.path]?.stamp != e.stamp)) {
        cache.changed = true;
      }
      cache.uncertain |= unavailable.isNotEmpty;
      final updated = state.entries.where((e) => !missing.contains(e.path)).map(
        (e) {
          final fresh = current[e.path];
          if (fresh == null) return e;
          return LocalBookEntry(
            path: fresh.path,
            name: fresh.name,
            directory: false,
            size: fresh.size,
            modified: fresh.modified,
            sortName: e.sortName,
            stamp: fresh.stamp,
          );
        },
      ).toList();
      // 跨目录保留的选择也要查重，不能只检查当前显示目录中的文件。
      final imported = await _findImported([
        ...updated,
        ...current.values,
      ], request);
      if (request != _request) return [];
      final prepared = await prepareLocalFiles(
        updated,
        state.sort,
        state.query,
      );
      if (request != _request) return [];
      _presentation++;
      state = state.copy(
        busy: false,
        accessDenied: false,
        entries: prepared.entries,
        visibleEntries: prepared.visible,
        imported: imported,
        selected: {...state.selected}
          ..removeWhere(
            (path, entry) =>
                missing.contains(path) ||
                imported.contains(path) ||
                _queued(entry),
          ),
        needsRescan: cache.changed,
        scanIncomplete: cache.uncertain,
        message: failed > 0 ? '$failed 个文件已失效或暂时无法读取，有效文件可继续导入' : null,
      );
      return [
        for (final e in entries)
          if (current.containsKey(e.path) &&
              !imported.contains(e.path) &&
              !_queued(e))
            current[e.path]!,
      ];
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '核验待导入文件失败');
      if (request == _request) {
        cache.uncertain = true;
        state = state.copy(
          busy: false,
          scanIncomplete: true,
          message: '无法核验文件，请检查权限后重试',
        );
      }
      return [];
    }
  }

  Future<Set<String>> _findImported(
    List<LocalBookEntry> entries,
    int request,
  ) async {
    if (purpose == LocalFilePurpose.fonts) {
      return ref.read(importedFontStoreProvider).findImported({
        for (final e in entries)
          if (!e.directory) e.path: e.size,
      });
    }
    final books = await ref.read(libraryBooksProvider.future);
    if (request != _request) return {};
    return ref
        .read(localImportMatcherProvider)
        .findImported(entries, books, cancelled: () => request != _request);
  }

  /// 导入期间返回文件页时，书架变化后重新匹配，整体发布已导入状态。
  Future<void> refreshImported() async {
    if (state.busy) return;
    final request = ++_request;
    state = state.copy(busy: true, scanning: false);
    final imported = await _findImported(state.entries, request);
    if (request != _request) return;
    state = state.copy(
      busy: false,
      imported: imported,
      selected: {...state.selected}
        ..removeWhere((path, _) => imported.contains(path)),
    );
  }

  void showMessage(String message) => state = state.copy(message: message);

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
    if (!await files.hasAccess()) {
      if (request == _request) {
        state = state.copy(
          busy: false,
          accessDenied: true,
          message: '文件访问权限已关闭，无法删除源文件',
        );
      }
      return;
    }
    if (request != _request) return;
    final removed = <String>{};
    for (final path in state.selected.keys) {
      if (request != _request) return;
      try {
        await files.delete(path);
        removed.add(path);
      } catch (appError, appStack) {
        AppErrors.report(appError, appStack, operation: '删除源文件失败');
        /* 保留失败项供重试。 */
      }
    }
    if (request != _request) return;
    final remaining = {...state.selected}
      ..removeWhere((key, _) => removed.contains(key));
    _cache.remove(removed);
    state = state.copy(
      busy: false,
      entries: state.entries.where((e) => !removed.contains(e.path)).toList(),
      selected: remaining,
      needsRescan: _cache.changed,
      message: remaining.isEmpty
          ? '已删除 ${removed.length} 个源文件'
          : '${remaining.length} 个文件删除失败，仍保留选中',
    );
  }
}
