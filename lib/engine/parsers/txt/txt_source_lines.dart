import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:direct_read_rust/direct_read_rust.dart';

import '../../../core/diagnostics/import_timing.dart';

/// 字节边界来自原文件，文字与规范化结果由同一 Rust 扫描器产生。
class TxtSourceLine {
  const TxtSourceLine(this.text, this.start, this.end, {this.normalizedText});
  final String text;
  final int start, end;
  final String? normalizedText;
}

class TxtSourceLines {
  TxtSourceLines(this.path, this.charset, {this.preparedPath});
  final String path, charset;
  final String? preparedPath;
  String digest = '';
  int byteCount = 0;
  Stream<TxtSourceLine> read({void Function(int)? onBytes}) async* {
    await for (final batch in readBatches(onBytes: onBytes)) {
      yield* Stream.fromIterable(batch);
    }
  }

  Stream<List<TxtSourceLine>> readBatches({
    void Function(int)? onBytes,
    int batchSize = 1024,
  }) async* {
    final timing = traceImportPerf ? ImportTiming('txt_source') : null;
    final nativeHash = ProcessingFeatures.nativeHash;
    final scan = NativeTxtStream(charset: charset, hashSource: nativeHash);
    final result = _DigestResult();
    final hash = sha256.startChunkedConversion(result);
    var batch = <TxtSourceLine>[];
    List<TxtSourceLine> convert(List<NativeTxtLine> lines) => [
      for (final line in lines)
        TxtSourceLine(
          line.text,
          line.start,
          line.end,
          normalizedText: line.normalized,
        ),
    ];

    try {
      await for (final bytes in File(path).openRead()) {
        if (nativeHash) {
          // The scanner hashes the same bytes during feed; no extra FFI or read.
        } else if (timing == null) {
          hash.add(bytes);
        } else {
          timing.detail('sha256', () => hash.add(bytes));
        }
        byteCount += bytes.length;
        onBytes?.call(bytes.length);
        final lines = timing == null
            ? scan.feed(bytes)
            : timing.detail(
                'native_decode_scan_transfer',
                () => scan.feed(bytes),
              );
        batch.addAll(convert(lines));
        while (batch.length >= batchSize) {
          yield batch.sublist(0, batchSize);
          batch = batch.sublist(batchSize);
        }
      }
      batch.addAll(convert(scan.feed(const [], finish: true)));
      if (nativeHash) {
        digest = scan.sourceDigest;
      } else {
        hash.close();
        digest = result.value.toString();
      }
      timing?.report(
        counts: {'sourceBytes': byteCount, 'nativeHash': nativeHash ? 1 : 0},
      );
      if (batch.isNotEmpty) yield batch;
    } finally {
      scan.close();
    }
  }
}

/// 编码预览及 Dart 对照仍使用；正文处理走 NativeTxtStream。
String decodeUtf8Range(List<int> bytes, int offset) {
  final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
  return offset > 0 &&
          bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf
      ? '\ufeff$text'
      : text;
}

class _DigestResult implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
