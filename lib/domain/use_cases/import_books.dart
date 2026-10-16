/// 导入流水线（设计文档 6.1）：
///
/// `选择文件 → 引用原路径 → 格式探测/路径去重 → 解析 → 标准化 →
/// 原子移动 → 数据库事务提交 → 书架可见`
///
/// 关键约束：
/// - 逐本提交，单本失败不影响其他书；
/// - 文件移动与数据库提交不是同一事务，用 `import_jobs` 记录阶段，
///   提交前的产物都在暂存目录，失败或取消时整体删除，不会出现半本可见书籍；
/// - 取消只在阶段边界检查，取消后立即释放句柄并清理暂存。
library;

import '../services/library_file_gate.dart';
import '../services/source_preparation_queue.dart';

import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/errors/import_error.dart';
import '../../core/diagnostics/import_timing.dart';
import '../../core/diagnostics/reader_work_trace.dart';
import '../../core/io/source_fingerprint.dart';
import '../models/book.dart';
import '../models/book_document.dart';
import '../models/import_job.dart';
import '../models/source_position_preparation.dart';
import '../models/locator.dart';
import '../repositories/book_repository.dart';
import '../services/book_parser.dart';
import '../services/document_platform.dart';
import '../services/import_storage.dart';
import '../services/book_content_change.dart';
import '../services/text_preparation.dart';

/// 单本文件的导入结果。
class ImportResult {
  const ImportResult({
    required this.key,
    required this.stage,
    this.bookId,
    this.failure,
    this.note,
  });

  /// 与 [ImportProgress.key] 对应，界面用它更新队列条目
  final String key;
  final ImportStage stage;

  /// 提交后可见的书籍 ID（done / duplicate 有值）
  final String? bookId;
  final ImportFailure? failure;

  /// 非致命提示（如「文件容器不完全符合 EPUB 规范」）
  final String? note;
}

/// TXT 导入前由用户在预览里确认的编码与章节规则。
class TxtImportChoice {
  const TxtImportChoice({
    this.charset,
    this.chapterPattern,
    this.forceSectionFallback = false,
  });

  final String? charset;
  final String? chapterPattern;
  final bool forceSectionFallback;
}

typedef ImportProgressCallback = void Function(ImportProgress progress);

class ImportBooksUseCase {
  /// 构造参数用私有命名形参：调用方写 `books:` / `platform:`，
  /// 类内直接持有 `_books` 等字段。
  ImportBooksUseCase({
    required this._books,
    required this._platform,
    required this._storage,
    required this._parsers,
    required this._textPreparation,
    this.prepareContentChange,
    this.fileGate,
    this.loadSourcePositions,
    this.optimizeLocations = true,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final BookRepository _books;
  final DocumentPlatform _platform;
  final ImportStorage _storage;
  final BookParserRegistry _parsers;
  final TextPreparationService _textPreparation;
  final Uuid _uuid;
  final PrepareBookContentChange? prepareContentChange;
  final LibraryFileGate? fileGate;
  final LoadSourcePositions? loadSourcePositions;
  /// 对照测试可分别关闭流程优化和 Rust 匹配，正式应用默认均开启。
  final bool optimizeLocations;

  /// 单次导入的源文件大小上限（设计文档 6.1 防护阈值初值）
  static const int maxSourceBytes = 200 * 1024 * 1024;

  /// 空间校验余量：复制与解析产物会同时存在，按源文件的 2.2 倍加余量估算
  static const int spaceHeadroomBytes = 32 * 1024 * 1024;

  /// 空间系数：暂存副本 + 正文产物
  static const double spaceFactor = 2.2;

  /// 分块大小，与平台侧上限一致
  static const int chunkBytes = 1024 * 1024;

  /// 格式探测读取的文件头长度
  static const int headerBytes = 64 * 1024;

  /// 依次导入一批已选文件。
  Future<List<ImportResult>> run(
    List<PickedDocument> documents, {
    required ImportProgressCallback onProgress,
    required CancelToken cancel,
    Map<String, TxtImportChoice> txtChoices = const {},
    Set<String> reparseKeys = const {},
  }) async {
    final results = <ImportResult>[];
    for (final picked in documents) {
      results.add(
        await importOne(
          picked,
          onProgress: onProgress,
          cancel: cancel,
          txtChoice: txtChoices[picked.uri],
          reparse: reparseKeys.contains(picked.uri),
        ),
      );
    }
    return results;
  }

  /// 导入单本文件。失败与取消都转换为 [ImportResult]，不向界面抛错。
  /// [reparse] 为 true 时忽略去重结果：用新的编码/章节规则重新解析，
  /// 复用原 bookId 替换正文（设计文档 6.3「允许修改规则后重新解析」）。
  final _queue = SourcePreparationQueue<ImportResult>();
  final _activeSources = <String, String>{};
  Future<ImportResult>? pendingForBook(Book book) => _queue.pending(
    _activeSources[book.id] ?? book.sourceHash,
    priority: true,
  );
  final _registrations = <String, Future<Book?>>{};

  /// 先保存本地来源与书籍身份，目录尚未就绪时明确为 preparing。
  /// content URI 需要平台复制，仍交给原流水线，不能伪造本地路径。
  Future<Book?> registerSource(PickedDocument picked) =>
      _registrations.putIfAbsent(
        picked.uri,
        () => _registerSource(picked).whenComplete(() {
          _registrations.remove(picked.uri);
        }),
      );

  Future<Book?> _registerSource(PickedDocument picked) async {
    final uri = Uri.parse(picked.uri);
    if (uri.scheme != 'file') return null;
    final path = p.normalize(uri.toFilePath());
    final identity = Uri.file(path).toString();
    final existing = await _books.findByHash(identity);
    if (existing != null && existing.status != BookStatus.removed) {
      return existing;
    }
    final format = BookFormat.fromCode(
      p.extension(picked.name).replaceFirst('.', '').toLowerCase(),
    );
    if (format != BookFormat.txt && format != BookFormat.epub) return null;
    final release = await fileGate?.enter();
    try {
      final book = Book(
        id: existing?.id ?? _uuid.v4(),
        sourceHash: identity,
        title: p.basenameWithoutExtension(picked.name),
        author: '',
        format: format!,
        importedAt: existing?.importedAt ?? DateTime.now().toUtc(),
        groupId: existing?.groupId,
        status: BookStatus.preparing,
        contentVersion: kContentVersion,
        sourceFileName: picked.name,
        sizeBytes: picked.sizeBytes ?? 0,
      );
      final commit = ImportCommit(book: book, chapters: const []);
      final directory = await _storage.bookDirectory(book.id);
      await _storage.writeBytes(
        p.join(directory, 'source.path'),
        utf8.encode(path),
      );
      if (existing == null) {
        await _books.commitImport(commit);
      } else {
        await _books.reactivateImport(commit);
      }
      return book;
    } finally {
      release?.call();
    }
  }

  /// 所有批次共享顺序，防止同一路径同时查重后分别入库。
  Future<ImportResult> importOne(
    PickedDocument picked, {
    required ImportProgressCallback onProgress,
    required CancelToken cancel,
    TxtImportChoice? txtChoice,
    bool reparse = false,
    String? replaceBookId,
    bool onlyIfPresent = false,
    bool priority = false,
  }) {
    return _queue.add(
      picked.uri,
      () => _importOne(
        picked,
        onProgress: onProgress,
        cancel: cancel,
        txtChoice: txtChoice,
        reparse: reparse,
        replaceBookId: replaceBookId,
        onlyIfPresent: onlyIfPresent,
      ),
      priority: priority,
    );
  }

  Future<ImportResult> _importOne(
    PickedDocument picked, {
    required ImportProgressCallback onProgress,
    required CancelToken cancel,
    TxtImportChoice? txtChoice,
    bool reparse = false,
    String? replaceBookId,
    bool onlyIfPresent = false,
  }) async {
    final timing = traceImportPerf ? ImportTiming('import_pipeline') : null;
    final trace = ReaderWorkTrace.start('import.pipeline', {
      'sourceKey': picked.uri.hashCode,
      'bookId': replaceBookId,
      'sourceScheme': Uri.tryParse(picked.uri)?.scheme,
      'reparse': reparse,
    });
    final key = picked.uri;
    final jobId = _uuid.v4();
    String? stagingDir;
    String? replacedContent, replacedBackup;
    var committed = false;
    String? preparingBookId;
    void Function()? releaseContent;
    void Function()? releaseBook;
    final releaseFiles = await fileGate?.enter();
    timing?.mark('file_gate_wait');
    trace?.mark('file_gate_wait');
    try {
      if (cancel.isCancelled(key)) {
        return ImportResult(key: key, stage: ImportStage.cancelled);
      }
      final sizeBytes = picked.sizeBytes;
      if (sizeBytes != null && sizeBytes > maxSourceBytes) {
        throw const ImportFailure(ImportErrorCode.tooLarge, '超过 200 MB');
      }

      stagingDir = await _storage.stagingDirectory(jobId);
      await _checkSpace(stagingDir, sizeBytes);
      await _books.upsertJob(
        ImportJobRecord(id: jobId, stage: 'copying', stagingPath: stagingDir),
      );

      // 本地书直接解析源文件，身份仅由完整路径决定，不复制或计算摘要。
      final uri = Uri.parse(picked.uri);
      final localPath = uri.scheme == 'file'
          ? p.normalize(uri.toFilePath())
          : null;
      trace?.details['sourceStorage'] = localPath == null
          ? 'platform_copy'
          : localPath.startsWith('/storage/') ||
                localPath.startsWith('/sdcard/')
          ? 'shared_storage'
          : 'app_or_other';
      final sourceIdentity = localPath == null
          ? picked.uri
          : Uri.file(localPath).toString();
      final sourceTmp = localPath ?? p.join(stagingDir, 'source.tmp');
      final copied = localPath != null
          ? CopiedFile(byteCount: await File(localPath).length(), sha256Hex: '')
          : await _copyToStaging(
              picked: picked,
              stagingDir: stagingDir,
              targetPath: sourceTmp,
              onProgress: onProgress,
              cancel: cancel,
            );
      if (copied.byteCount == 0) {
        throw const ImportFailure(ImportErrorCode.emptyFile);
      }
      if (copied.byteCount > maxSourceBytes) {
        throw const ImportFailure(ImportErrorCode.tooLarge, '超过 200 MB');
      }

      // 2) 真实格式探测（只认文件头，不信任扩展名）
      final header = await _readHeader(sourceTmp);
      final format = _parsers.probe(
        FileProbe(
          header: header,
          sizeBytes: copied.byteCount,
          fileName: picked.name,
        ),
      );
      if (format == null) {
        throw const ImportFailure(ImportErrorCode.unsupportedFormat);
      }
      if (format == BookFormat.mobi) {
        throw const ImportFailure(
          ImportErrorCode.unsupportedFormat,
          'MOBI 将在后续版本支持',
        );
      }

      // 同一路径（包含文件名）去重；改名、复制或移动后允许作为新书导入。
      final existing = reparse && replaceBookId != null
          ? await _books.findById(replaceBookId)
          : await _books.findByHash(sourceIdentity);
      if (existing != null &&
          existing.status != BookStatus.removed &&
          existing.status != BookStatus.preparing &&
          !reparse) {
        // 重复文件同样要清掉暂存目录与 journal，否则会留下一条永远不结束的任务
        await _storage.deleteRecursively(stagingDir);
        await _books.deleteJob(jobId);
        onProgress(
          ImportProgress(
            key: key,
            stage: ImportStage.duplicate,
            bookId: existing.id,
          ),
        );
        return ImportResult(
          key: key,
          stage: ImportStage.duplicate,
          bookId: existing.id,
          note: '书架中已有《${existing.title}》',
        );
      }

      // 本地原文件始终留在用户目录；兼容旧系统文件接口的私有副本。
      final bookId = existing?.id ?? _uuid.v4();
      preparingBookId = bookId;
      trace?.details['bookId'] = bookId;
      trace?.details['sourceBytes'] = copied.byteCount;
      _activeSources[bookId] = key;
      releaseBook = await fileGate?.enterBook(bookId);
      timing?.mark('source_probe_and_book_gate');
      if (onlyIfPresent) {
        final current = await _books.findById(bookId);
        if (current == null || current.status == BookStatus.removed) {
          throw const ImportFailure(ImportErrorCode.cancelled);
        }
      }
      if (existing != null) {
        releaseContent = await prepareContentChange?.call(bookId);
      }
      timing?.mark('prepare_previous_content');
      final bookDir = await _storage.bookDirectory(bookId);
      final sourcePath = localPath ?? p.join(bookDir, 'source.${format.code}');
      if (localPath == null) {
        await _storage.deleteRecursively(sourcePath);
        await _storage.move(from: sourceTmp, to: sourcePath);
      }

      // 5) 解析到暂存产物目录；TXT 先转成 UTF-8 文本
      await _books.upsertJob(
        ImportJobRecord(
          id: jobId,
          stage: 'parsing',
          stagingPath: stagingDir,
          targetBookId: bookId,
        ),
      );
      onProgress(ImportProgress(key: key, stage: ImportStage.parsing));

      final contentStaging = p.join(stagingDir, 'content');
      await _storage.ensureDirectory(contentStaging);
      timing?.mark('prepare_source_probe_job');
      final beforeParse = localPath == null
          ? null
          : await File(sourcePath).stat();
      final oldPositions = optimizeLocations && loadSourcePositions != null && existing != null
          ? await loadSourcePositions!(bookId) : const SourcePositionPreparation();
      final positionRules = sourcePositionRules(format.code,
        charset: format == BookFormat.txt
            ? txtChoice?.charset ?? _textPreparation.detectEncoding(header).charset : null,
        chapterPattern: txtChoice?.chapterPattern,
        forceSections: txtChoice?.forceSectionFallback ?? false);
      // 属性没变时可避免连带匹配；最终仍比较本次扫描得到的摘要，才决定复用。
      final unchangedStamp = beforeParse != null &&
          oldPositions.proof?.rules == positionRules &&
          oldPositions.proof?.stamp == sourceFingerprint(beforeParse);
      final anchors = [for (final point in oldPositions.anchors)
        if (!unchangedStamp || point.needsRelocation) point.copyWith(needsRelocation: true)];
      final document = await _parse(
        picked: picked,
        format: format,
        header: header,
        sourcePath: sourcePath,
        contentStaging: contentStaging,
        txtChoice: txtChoice,
        cancel: cancel,
        key: key,
        onProgress: onProgress,
        anchors: anchors,
      );
      timing?.mark('parse_worker_roundtrip');
      trace?.details.addAll({
        'chapters': document.chapters.length,
        'sourceDigest': document.sourceIndex?.sourceDigest,
      });
      if (format == BookFormat.txt) {
        await _storage.writeBytes(
          p.join(contentStaging, 'txt.options'),
          utf8.encode(
            jsonEncode({
              'charset': txtChoice?.charset,
              'chapterPattern': txtChoice?.chapterPattern,
              'forceSectionFallback': txtChoice?.forceSectionFallback ?? false,
            }),
          ),
        );
      }
      if (beforeParse != null) {
        final afterParse = await File(sourcePath).stat();
        if (beforeParse.size != afterParse.size ||
            beforeParse.modified != afterParse.modified ||
            beforeParse.changed != afterParse.changed) {
          throw const ImportFailure(ImportErrorCode.unknown, '文件正在修改，请稍后重试');
        }
      }
      if (cancel.isCancelled(key)) {
        throw const ImportFailure(ImportErrorCode.cancelled);
      }

      // 6) 原子移动正文目录，再由数据库事务让书籍可见
      onProgress(
        ImportProgress(key: key, stage: ImportStage.committing, bookId: bookId),
      );
      final contentTarget = p.join(
        bookDir,
        'content',
        '${document.contentVersion}',
      );
      await _storage.ensureDirectory(p.dirname(contentTarget));
      if (reparse &&
          existing != null &&
          await Directory(contentTarget).exists()) {
        // 重导入只有新解析全部成功才替换；提交失败还能恢复旧索引及资源。
        replacedContent = contentTarget;
        replacedBackup = p.join(stagingDir, 'previous_content');
        await _storage.move(from: contentTarget, to: replacedBackup);
      } else {
        await _storage.deleteRecursively(contentTarget);
      }
      await _storage.move(from: contentStaging, to: contentTarget);
      if (localPath != null) {
        await _storage.writeBytes(
          p.join(bookDir, 'source.path'),
          utf8.encode(localPath),
        );
      }

      final book = _buildBook(
        bookId: bookId,
        format: format,
        document: document,
        sourceHash: sourceIdentity,
        sizeBytes: copied.byteCount,
        bookDir: bookDir,
        sourceFileName: picked.name,
        previous: reparse || existing?.status == BookStatus.preparing
            ? existing
            : null,
      );
      final index = document.sourceIndex;
      final proof = index == null ? null : SourcePositionProof(
        index.sourceDigest, positionRules, index.sourceStamp ?? '');
      final sameContent = optimizeLocations && proof != null &&
          oldPositions.proof?.sameContent(proof) == true;
      trace?.details.addAll({'samePositionContent': sameContent,
        'locationQueries': anchors.length});
      final commit = ImportCommit(
        book: book,
        chapters: document.chapters,
        sourceChanged: existing != null && !sameContent,
        positionProof: proof,
      );
      timing?.mark('publish_files');
      if (existing == null) {
        await _books.commitImport(commit);
      } else {
        await _books.reactivateImport(commit);
      }
      timing?.mark('database_commit');
      committed = true;
      await _books.deleteJob(jobId);
      await _storage.deleteRecursively(stagingDir);
      timing?.mark('cleanup');

      final note = document.warnings.isEmpty ? null : document.warnings.first;
      onProgress(
        ImportProgress(
          key: key,
          stage: ImportStage.done,
          bookId: bookId,
          note: note,
        ),
      );
      return ImportResult(
        key: key,
        stage: ImportStage.done,
        bookId: bookId,
        note: note,
      );
    } catch (error) {
      if (!committed && replacedBackup != null && replacedContent != null) {
        await _storage.deleteRecursively(replacedContent);
        await _storage.move(from: replacedBackup, to: replacedContent);
      }
      return await _handleFailure(
        key: key,
        jobId: jobId,
        stagingDir: stagingDir,
        error: error,
        cancel: cancel,
      );
    } finally {
      trace?.finish();
      if (preparingBookId != null) _activeSources.remove(preparingBookId);
      releaseContent?.call();
      releaseBook?.call();
      releaseFiles?.call();
      timing?.report();
    }
  }

  /// 失败与取消的统一收尾：删暂存、清 journal。
  Future<ImportResult> _handleFailure({
    required String key,
    required String jobId,
    required String? stagingDir,
    required Object error,
    required CancelToken cancel,
  }) async {
    if (stagingDir != null) {
      try {
        await _storage.deleteRecursively(stagingDir);
      } catch (_) {
        // 清理失败时留给下次启动的 cleanupInterruptedImports 兜底
      }
    }
    try {
      await _books.deleteJob(jobId);
    } catch (_) {
      // 同上：journal 只用于恢复，允许清理失败
    }
    final failure = error is ImportFailure
        ? error
        : ImportFailure(ImportErrorCode.unknown, '$error');
    final cancelled =
        failure.code == ImportErrorCode.cancelled || cancel.isCancelled(key);
    return ImportResult(
      key: key,
      stage: cancelled ? ImportStage.cancelled : ImportStage.failed,
      failure: cancelled ? null : failure,
    );
  }

  /// 空间校验：复制与解析产物同时存在，按估算值判断。
  Future<void> _checkSpace(String stagingDir, int? sizeBytes) async {
    final available = await _platform.availableBytes(stagingDir);
    if (available <= 0) return; // 平台取不到剩余空间时不阻塞导入
    final needed = sizeBytes == null
        ? spaceHeadroomBytes
        : (sizeBytes * spaceFactor).round() + spaceHeadroomBytes;
    if (available < needed) {
      throw ImportFailure(
        ImportErrorCode.noSpace,
        '需要约 ${(needed / 1024 / 1024).round()} MB',
      );
    }
  }

  /// 非文件路径的平台文档接口保留分块读取；本地文件不经过此方法。
  Future<CopiedFile> _copyToStaging({
    required PickedDocument picked,
    required String stagingDir,
    required String targetPath,
    required ImportProgressCallback onProgress,
    required CancelToken cancel,
  }) async {
    final session = await _platform.open(picked.uri);
    try {
      final copied = await _storage.copyStream(
        targetPath: targetPath,
        readChunk: () => _platform.readChunk(session, chunkBytes),
        onProgress: (copiedBytes) => onProgress(
          ImportProgress(
            key: picked.uri,
            stage: ImportStage.copying,
            copiedBytes: copiedBytes,
            totalBytes: picked.sizeBytes ?? session.sizeBytes,
          ),
        ),
        isCancelled: () => cancel.isCancelled(picked.uri),
      );
      if (copied.byteCount == 0) {
        throw const ImportFailure(ImportErrorCode.emptyFile);
      }
      return copied;
    } finally {
      await _platform.close(session);
    }
  }

  /// 解析：TXT 先转码成 UTF-8 文本，再进入 worker isolate。
  Future<BookDocument> _parse({
    required PickedDocument picked,
    required BookFormat format,
    required Uint8List header,
    required String sourcePath,
    required String contentStaging,
    required TxtImportChoice? txtChoice,
    required CancelToken cancel,
    required String key,
    required ImportProgressCallback onProgress,
    required List<Locator> anchors,
  }) async {
    // 所有支持编码都由后台 Rust 直接扫描原字节，不生成全文转码副本。
    var charset = txtChoice?.charset;
    String? textPath;
    if (format == BookFormat.txt) {
      charset ??= _textPreparation.detectEncoding(header).charset;
      textPath = sourcePath;
    }
    if (cancel.isCancelled(key)) {
      throw const ImportFailure(ImportErrorCode.cancelled);
    }

    final request = ParseRequest(
      format: format,
      sourcePath: sourcePath,
      displayName: picked.name,
      workDir: contentStaging,
      contentVersion: kContentVersion,
      textPath: textPath,
      indexedContent: true,
      locationAnchors: anchors,
      txt: format == BookFormat.txt
          ? TxtOptions(
              charset: charset,
              chapterPattern: txtChoice?.chapterPattern,
              forceSectionFallback: txtChoice?.forceSectionFallback ?? false,
            )
          : null,
    );
    final document = await _parsers.parse(
      request,
      onCover: (bytes) => onProgress(
        ImportProgress(key: key, stage: ImportStage.parsing, coverBytes: bytes),
      ),
      onProgress: (fraction) => onProgress(
        ImportProgress(
          key: key,
          stage: ImportStage.parsing,
          fraction: fraction,
        ),
      ),
      cancel: cancel,
    );
    return document;
  }

  /// 组装写入数据库的书籍实体。
  Book _buildBook({
    required String bookId,
    required BookFormat format,
    required BookDocument document,
    required String sourceHash,
    required int sizeBytes,
    required String bookDir,
    required String sourceFileName,
    Book? previous,
  }) {
    return Book(
      id: bookId,
      sourceHash: sourceHash,
      title: document.title.isEmpty ? '未命名书籍' : document.title,
      sourceFileName: sourceFileName,
      author: document.author,
      format: format,
      contentVersion: document.contentVersion,
      importedAt: previous?.importedAt ?? DateTime.now().toUtc(),
      groupId: previous?.groupId,
      sizeBytes: sizeBytes,
      coverPath: document.coverPath == null
          ? null
          : p.join(
              'content',
              '${document.contentVersion}',
              document.coverPath!,
            ),
      coverWidth: document.coverWidth,
      coverHeight: document.coverHeight,
      textLength: document.textLength,
      chapterCount: document.chapters.length,
      warnings: document.warnings,
    );
  }

  /// 读取文件头，用于格式探测与编码识别。
  Future<Uint8List> _readHeader(String path) async {
    final file = File(path);
    final length = await file.length();
    final size = length < headerBytes ? length : headerBytes;
    final handle = await file.open();
    try {
      return await handle.read(size);
    } finally {
      await handle.close();
    }
  }
}
