import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../core/errors/import_error.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/import_job.dart';
import '../../../../domain/services/book_parser.dart';
import '../../../../domain/services/document_platform.dart';
import '../../../../domain/use_cases/import_books.dart';

/// 导入队列中的一条文件记录。
class ImportItem {
  const ImportItem({
    required this.document,
    this.format,
    this.stage = ImportStage.waiting,
    this.copiedBytes = 0,
    this.parseFraction,
    this.bookId,
    this.failure,
    this.note,
    this.charset,
    this.charsetConfident = false,
    this.sample,
    this.txtChoice,
    this.coverBytes,
  });

  final PickedDocument document;

  /// 文件头探测出的真实格式；null 表示暂未探测或不支持
  final BookFormat? format;
  final ImportStage stage;

  /// 已复制字节（复制阶段）
  final int copiedBytes;

  /// 解析进度 0–1；null 表示不定进度
  final double? parseFraction;
  final String? bookId;
  final Uint8List? coverBytes;

  final ImportFailure? failure;
  final String? note;

  /// TXT 识别出的编码与置信度
  final String? charset;
  final bool charsetConfident;

  /// 供编码预览使用的文件头样本
  final Uint8List? sample;

  /// 用户在预览面板里确认过的编码与章节规则
  final TxtImportChoice? txtChoice;

  String get key => document.uri;

  bool get isRunning =>
      stage == ImportStage.copying ||
      stage == ImportStage.parsing ||
      stage == ImportStage.committing;

  bool get isTxt => format == BookFormat.txt;

  /// 「已选 3 本 · 128 MB」中的体积部分
  String get sizeLabel => _formatBytes(document.sizeBytes);

  /// 复制进度 0–1；大小未知时为 null
  double? get copyFraction {
    final total = document.sizeBytes;
    if (total == null || total <= 0) return null;
    return (copiedBytes / total).clamp(0.0, 1.0);
  }

  ImportItem copyWith({
    BookFormat? format,
    ImportStage? stage,
    int? copiedBytes,
    double? parseFraction,
    String? bookId,
    ImportFailure? failure,
    bool clearFailure = false,
    String? note,
    bool clearNote = false,
    String? charset,
    bool? charsetConfident,
    Uint8List? sample,
    TxtImportChoice? txtChoice,
    Uint8List? coverBytes,
  }) {
    return ImportItem(
      document: document,
      format: format ?? this.format,
      stage: stage ?? this.stage,
      copiedBytes: copiedBytes ?? this.copiedBytes,
      parseFraction: parseFraction ?? this.parseFraction,
      bookId: bookId ?? this.bookId,
      failure: clearFailure ? null : (failure ?? this.failure),
      note: clearNote ? null : (note ?? this.note),
      charset: charset ?? this.charset,
      charsetConfident: charsetConfident ?? this.charsetConfident,
      sample: sample ?? this.sample,
      txtChoice: txtChoice ?? this.txtChoice,
      coverBytes: coverBytes ?? this.coverBytes,
    );
  }
}

/// 导入页状态。
class ImportState {
  const ImportState({
    this.items = const [],
    this.picking = false,
    this.running = false,
  });

  final List<ImportItem> items;

  /// 正在等待系统选择器返回
  final bool picking;

  /// 队列里还有任务在跑
  final bool running;

  int get totalBytes => items.fold(
        0,
        (sum, item) => sum + (item.document.sizeBytes ?? 0),
      );

  String get summary => '已选 ${items.length} 本 · ${_formatBytes(totalBytes)}';

  ImportState copyWith({
    List<ImportItem>? items,
    bool? picking,
    bool? running,
  }) {
    return ImportState(
      items: items ?? this.items,
      picking: picking ?? this.picking,
      running: running ?? this.running,
    );
  }

  /// 需要用户在导入前确认编码的 TXT（自动识别结果不确定）
  List<ImportItem> get pendingTxtConfirmation =>
      items.where((i) => i.isTxt && !i.charsetConfident).toList();
}

class ImportViewModel extends Notifier<ImportState> {
  /// 先发布待导入条目，再后台读取；TXT 编码和章节规则使用流水线自动识别。
  void enqueue(List<PickedDocument> documents) {
    if (_running.isEmpty) _cancel.reset();
    final existingIds = ref.read(libraryBooksProvider).value?.map((b) => b.id).toSet() ?? <String>{};
    final imported = {for (final item in state.items)
      if (item.stage.isFinished && existingIds.contains(item.bookId)) item.key};
    final added = [for (final document in documents)
      if (!_running.contains(document.uri) && !imported.contains(document.uri))
        ImportItem(document: document)];
    state = state.copyWith(items: _merge(state.items, added));
    _run(added.map((item) => item.key).toSet());
  }
  final CancelToken _cancel = CancelToken();

  /// 正在导入的条目，避免重复点击「重试」把同一本导两遍
  final Set<String> _running = <String>{};
  final _batches = <Completer<void>>{};

  /// 交接期间界面已阻止新操作；等整批队列而不是只等当前一本书。
  Future<void> waitForIdle() async {
    while (_batches.isNotEmpty) {
      await Future.wait(_batches.map((batch) => batch.future).toList());
    }
  }

  @override
  ImportState build() => const ImportState();

  /// 选择文件并开始导入。
  ///
  /// 返回需要用户确认编码的条目；界面据此弹出编码预览面板。
  Future<List<ImportItem>> pick({List<PickedDocument>? documents}) async {
    if (state.picking) return const [];
    state = state.copyWith(picking: true);
    List<PickedDocument> picked;
    try {
      picked = documents ?? await ref.read(documentPlatformProvider).pickDocuments();
    } finally {
      state = state.copyWith(picking: false);
    }
    if (picked.isEmpty) return const [];

    // 只探测文件头：真实格式与 TXT 编码都在这里定下来
    final items = <ImportItem>[];
    for (final document in picked) {
      // 同一个文件正在导入：不再往队列里排一条（否则这一条永远等不到自己的进度）
      if (_running.contains(document.uri)) continue;
      items.add(await _inspect(document));
    }
    state = state.copyWith(items: _merge(state.items, items));
    return items.where((i) => i.isTxt && !i.charsetConfident).toList();
  }

  /// 新挑的文件并入队列：同一个文件（[ImportItem.key] 相同）替换掉原记录。
  ///
  /// 队列在离开导入页后还留着（导入完成的条目要能改编码重导），所以把同一本书
  /// 删掉再导入时，旧记录还在队列里。直接追加会出现两条同名记录，进度更新
  /// 按 key 找记录，两条会一起动；这里按 key 合并成一条。
  List<ImportItem> _merge(List<ImportItem> existing, List<ImportItem> added) {
    final merged = [...existing];
    for (final item in added) {
      final index = merged.indexWhere((old) => old.key == item.key);
      if (index >= 0) {
        merged[index] = item;
      } else {
        merged.add(item);
      }
    }
    return merged;
  }

  /// 用户在预览面板确认编码与章节规则后启动导入。
  void start(List<ImportItem> inspected, Map<String, TxtImportChoice> choices) {
    if (inspected.isEmpty) return;
    state = state.copyWith(
      items: [
        for (final item in state.items)
          choices.containsKey(item.key)
              ? item.copyWith(txtChoice: choices[item.key])
              : item,
      ],
    );
    _run(inspected.map((i) => i.key).toSet());
  }

  /// 在编码面板里改了编码或章节规则后（重新）导入这一本。
  ///
  /// 已经导入成功的 TXT 会按新规则重新解析并替换正文，复用书籍 ID，
  /// 不产生第二本书。
  void startRetryWithChoice(ImportItem item, TxtImportChoice choice) {
    final reparse = item.stage == ImportStage.done ||
        item.stage == ImportStage.duplicate;
    _update(
      item.key,
      item.copyWith(
        txtChoice: choice,
        stage: ImportStage.waiting,
        copiedBytes: 0,
        parseFraction: 0,
        clearFailure: true,
        clearNote: true,
      ),
    );
    _run({item.key}, reparseKeys: reparse ? {item.key} : const {});
  }

  /// 取消某一本：直接从队列移除这条记录，不留「已取消」占位。
  ///
  /// 流水线侧收到取消信号后会停止复制/解析，并清掉暂存目录与任务记录，
  /// 所以库里、缓存里都不会留下这次导入的任何东西。
  void cancel(String key) {
    _cancel.cancel(key);
    _remove(key);
  }

  /// 取消整批：尚未结束的条目全部从队列移除。
  void cancelAll() {
    _cancel.cancelAll();
    state = state.copyWith(
      items: [for (final item in state.items) if (item.stage.isFinished) item],
    );
  }

  /// 重试失败或已取消的条目。
  void retry(String key) {
    final item = _find(key);
    if (item == null || item.isRunning) return;
    _update(key, item.copyWith(
      stage: ImportStage.waiting,
      copiedBytes: 0,
      parseFraction: 0,
      clearFailure: true,
    ));
    _run({key});
  }

  /// 清空已结束的队列条目。
  void clearFinished() {
    state = state.copyWith(
      items: [
        for (final item in state.items)
          if (!item.stage.isFinished) item,
      ],
    );
  }

  void dismissFinished(String key) {
    if (_find(key)?.stage.isFinished ?? false) _remove(key);
  }

  /// 依次导入指定条目；单本失败不影响其他书。
  Future<void> _run(Set<String> keys, {Set<String> reparseKeys = const {}}) async {
    final targets = [
      for (final item in state.items)
        if (keys.contains(item.key) &&
            !item.stage.isFinished &&
            !_running.contains(item.key))
          item,
    ];
    if (targets.isEmpty) return;
    final batch = Completer<void>();
    _batches.add(batch);
    final remaining = targets.map((i) => i.key).toSet();
    _running.addAll(remaining);
    state = state.copyWith(running: true);
    try {
      final useCase = ref.read(importBooksProvider);
      final choices = {
        for (final item in targets)
          if (item.txtChoice != null) item.key: item.txtChoice!,
      };
      for (final target in targets) {
        final result = await useCase.importOne(
        target.document,
        onProgress: _onProgress,
        cancel: _cancel,
        txtChoice: choices[target.key],
        reparse: reparseKeys.contains(target.key),
      );
        remaining.remove(result.key);
        _running.remove(result.key);
        // 取消的条目已经不在队列里，也不需要再更新状态
        if (_cancel.isCancelled(result.key)) continue;
        final current = _find(result.key);
        if (current == null) continue;
        _update(
          result.key,
          current.copyWith(
            stage: result.stage,
            bookId: result.bookId,
            failure: result.failure,
            clearFailure: result.failure == null,
            note: result.note,
          ),
        );
      }
    } finally {
      _running.removeAll(remaining);
      state = state.copyWith(running: _running.isNotEmpty);
      _batches.remove(batch);
      batch.complete();
    }
  }

  void _onProgress(ImportProgress progress) {
    final item = _find(progress.key);
    if (item == null) return;
    final stage = switch (progress.stage) {
      ImportStage.copying => ImportStage.copying,
      ImportStage.parsing => ImportStage.parsing,
      ImportStage.committing => ImportStage.committing,
      ImportStage.done => ImportStage.done,
      ImportStage.duplicate => ImportStage.duplicate,
      _ => item.stage,
    };
    _update(
      progress.key,
      item.copyWith(
        stage: stage,
        bookId: progress.bookId,
        coverBytes: progress.coverBytes,
        copiedBytes: progress.copiedBytes,
        parseFraction: progress.fraction,
        note: progress.note,
      ),
    );
  }

  /// 读取文件头，探测真实格式与 TXT 编码。
  Future<ImportItem> _inspect(PickedDocument document) async {
    final platform = ref.read(documentPlatformProvider);
    Uint8List? sample;
    DocumentSession? session;
    try {
      session = await platform.open(document.uri);
      sample = await platform.readChunk(session, 64 * 1024) ?? Uint8List(0);
    } catch (_) {
      // 打不开的条目交给导入流水线给出失败原因
      sample = null;
    } finally {
      if (session != null) {
        try {
          await platform.close(session);
        } catch (_) {
          // 关闭失败不影响后续导入：导入时会重新打开
        }
      }
    }

    if (sample == null) return ImportItem(document: document);

    final format = ref.read(parserRegistryProvider).probe(FileProbe(
          header: sample,
          sizeBytes: document.sizeBytes ?? 0,
          fileName: document.name,
        ));
    if (format != BookFormat.txt) {
      return ImportItem(document: document, format: format);
    }
    final guess = ref.read(textPreparationProvider).detectEncoding(sample);
    return ImportItem(
      document: document,
      format: format,
      charset: guess.charset,
      charsetConfident: guess.confident,
      sample: sample,
    );
  }

  ImportItem? _find(String key) {
    for (final item in state.items) {
      if (item.key == key) return item;
    }
    return null;
  }

  /// 把某条记录从队列里去掉。
  void _remove(String key) {
    state = state.copyWith(
      items: [for (final item in state.items) if (item.key != key) item],
    );
  }

  void _update(String key, ImportItem updated) {
    state = state.copyWith(
      items: [
        for (final item in state.items) item.key == key ? updated : item,
      ],
    );
  }
}

final importProvider =
    NotifierProvider<ImportViewModel, ImportState>(ImportViewModel.new);

/// 字节数 → 「12.4 MB」。
String _formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '未知大小';
  const unit = 1024;
  if (bytes < unit) return '$bytes B';
  if (bytes < unit * unit) return '${(bytes / unit).toStringAsFixed(1)} KB';
  if (bytes < unit * unit * unit) {
    return '${(bytes / unit / unit).toStringAsFixed(1)} MB';
  }
  return '${(bytes / unit / unit / unit).toStringAsFixed(2)} GB';
}

/// 供界面显示文件体积。
String formatFileSize(int? bytes) => _formatBytes(bytes);
