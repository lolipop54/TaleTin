/// 解析工作的可取消 worker isolate（设计文档 6.1）。
///
/// 解压与正文转换放在每任务独立的 worker 里：取消即终止 worker，
/// worker 只写调用方给出的暂存目录，终止不会留下可见的半本书。
/// worker 内不能使用平台通道，因此 TXT 的转码在进入 worker 之前完成。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:direct_read_rust/direct_read_rust.dart';

import '../../core/diagnostics/import_timing.dart';
import '../../core/errors/import_error.dart';
import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/import_job.dart';
import '../../domain/services/book_parser.dart';
import 'epub/epub_parser.dart';
import 'txt/txt_parser.dart';
import '../normalization/source_position_cache.dart';
import '../../domain/models/source_position_preparation.dart';

/// 在 worker isolate 里执行一次解析。
class ParseWorker {
  const ParseWorker();

  Future<BookDocument> run({
    required ParseRequest request,
    required ParseProgress onProgress,
    required CancelToken cancel,
    ParseCover? onCover,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await _spawn(request, receivePort.sendPort);
    final completer = Completer<BookDocument>();
    var settled = false;

    // 取消即终止 worker（设计文档 6.1）：token 不是事件流，这里按固定间隔轮询
    final cancelWatch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (settled || !cancel.isCancelled()) return;
      settled = true;
      isolate.kill(priority: Isolate.immediate);
      completer.completeError(const ImportFailure(ImportErrorCode.cancelled));
    });

    receivePort.listen((message) {
      if (settled) return;
      if (message is Map) {
        if (message['cover'] case final Uint8List bytes) {
          onCover?.call(bytes);
          return;
        }
        if (message.containsKey('progress')) {
          onProgress((message['progress'] as num?)?.toDouble());
          return;
        }
        final document = message['document'];
        if (document is BookDocument) {
          settled = true;
          completer.complete(document);
          return;
        }
        final failure = message['failure'];
        if (failure is String) {
          settled = true;
          completer.completeError(
            ImportFailure(
              ImportErrorCode.fromCode(failure),
              message['detail'] as String?,
            ),
          );
        }
        return;
      }
      // onExit：worker 提前结束且没有回传结果
      settled = true;
      completer.completeError(
        cancel.isCancelled()
            ? const ImportFailure(ImportErrorCode.cancelled)
            : const ImportFailure(ImportErrorCode.unknown, '解析进程提前结束'),
      );
    });

    try {
      return await completer.future;
    } finally {
      cancelWatch.cancel();
      receivePort.close();
      // 正常结束或异常都终止 worker，释放解析期间占用的内存
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static Future<Isolate> _spawn(ParseRequest request, SendPort sendPort) async {
    final errors = ReceivePort();
    try {
      return await Isolate.spawn(
        _workerMain,
        _WorkerRequest(
          request: request,
          sendPort: sendPort,
          features: ProcessingFeatures.mask,
        ),
        onError: errors.sendPort,
        onExit: sendPort,
        errorsAreFatal: true,
        debugName: 'gt-parse-${request.format.code}',
      );
    } on IsolateSpawnException catch (error) {
      throw ImportFailure(ImportErrorCode.unknown, '解析任务启动失败：$error');
    } finally {
      errors.close();
    }
  }
}

/// 传给 worker 的参数。
class _WorkerRequest {
  const _WorkerRequest({
    required this.request,
    required this.sendPort,
    required this.features,
  });

  final ParseRequest request;
  final SendPort sendPort;
  final int features;
}

/// worker 入口：解析 + 写清单，结果与进度经 [SendPort] 回传。
Future<void> _workerMain(_WorkerRequest message) async {
  ProcessingFeatures.configureExperiment(message.features);
  final sendPort = message.sendPort;
  final request = message.request;
  final timing = traceImportPerf && request.format == BookFormat.epub
      ? ImportTiming('epub_worker')
      : null;
  try {
    final BookDocument document;
    final sourceBefore = request.indexedContent
        ? File(request.sourcePath).statSync()
        : null;
    if (request.format == BookFormat.txt) {
      document = await const TxtParser().parse(
        request,
        onProgress: (fraction) => sendPort.send({'progress': fraction}),
        isCancelled: _neverCancelled,
      );
    } else {
      document = await const EpubParser().parse(
        request,
        onCover: (bytes) => sendPort.send({'cover': bytes}),
        onProgress: (fraction) => sendPort.send({'progress': fraction}),
        isCancelled: _neverCancelled,
      );
    }
    timing?.mark('parser');
    if (sourceBefore != null) {
      final after = File(request.sourcePath).statSync();
      if (sourceBefore.size != after.size ||
          sourceBefore.modified != after.modified) {
        throw const ImportFailure(
          ImportErrorCode.decodeFailed,
          '导入期间原文件发生变化，请重试',
        );
      }
    }
    _writeManifest(request, document);
    timing?.mark('manifest_encode_write');
    timing?.report();
    sendPort.send({'document': document});
  } on ImportFailure catch (failure) {
    sendPort.send({'failure': failure.code.code, 'detail': failure.detail});
  } catch (error) {
    sendPort.send({
      'failure': ImportErrorCode.unknown.code,
      'detail': '$error',
    });
  }
}

/// 写 `content/<版本>/manifest.json`：封面、嵌套目录、章节清单与提示。
void _writeManifest(ParseRequest request, BookDocument document) {
  final file = File(p.join(request.workDir, 'manifest.json'));
  file.parent.createSync(recursive: true);
  final manifest = document.toManifestJson();
  manifest['positionRules'] = sourcePositionRules(request.format.code,
    charset: request.txt?.charset, chapterPattern: request.txt?.chapterPattern,
    forceSections: request.txt?.forceSectionFallback ?? false);
  file.writeAsStringSync(jsonEncode(manifest), flush: false);
  SourcePositionCache.write(request.workDir, document.locationMatches);
}

/// worker 内的取消恒为 false：取消由主 isolate 直接终止 worker 完成。
bool _neverCancelled() => false;
