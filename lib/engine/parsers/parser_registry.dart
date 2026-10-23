/// 解析器注册表：真实格式探测 + 派发到 worker。
///
/// 扩展名只作参考，格式以文件头为准（设计文档 6.1「去重时序」）。
library;

import 'dart:typed_data';

import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/import_job.dart';
import '../../domain/services/book_parser.dart';
import 'parse_worker.dart';
import 'txt/encoding_detector.dart';

class ParserRegistry implements BookParserRegistry {
  ParserRegistry({ParseWorker? worker}) : _worker = worker ?? const ParseWorker();

  final ParseWorker _worker;

  @override
  BookFormat? probe(FileProbe probe) {
    final header = probe.header;
    if (header.isEmpty) return null;

    // 1) ZIP：合法 ZIP 一律当 EPUB 交给完整解析，容器是否规范由解析结果判定
    if (_startsWith(header, const [0x50, 0x4B, 0x03, 0x04]) ||
        _startsWith(header, const [0x50, 0x4B, 0x05, 0x06])) {
      return BookFormat.epub;
    }

    // MOBI 和 AZW3 共用 Palm 容器；保留来源扩展名供备份和恢复使用。
    if (_isMobi(header)) {
      return probe.extension == 'azw3' ? BookFormat.azw3 : BookFormat.mobi;
    }

    // 3) PDF 等已知不支持格式直接拒绝
    if (_startsWith(header, const [0x25, 0x50, 0x44, 0x46])) return BookFormat.pdf;

    // 4) 其余按文本判断：出现零字节且不是 UTF-16 时视为二进制
    final guess = detectEncoding(header);
    final utf16Like =
        guess.charset == 'UTF-16LE' || guess.charset == 'UTF-16BE';
    if (!utf16Like && _containsZero(header)) return null;
    return BookFormat.txt;
  }

  @override
  Future<BookDocument> parse(
    ParseRequest request, {
    required ParseProgress onProgress,
    required CancelToken cancel,
    ParseCover? onCover,
  }) async {
    return _worker.run(
      request: request,
      onProgress: onProgress,
      cancel: cancel,
      onCover: onCover,
    );
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _containsZero(Uint8List bytes) {
    final limit = bytes.length > 1024 ? 1024 : bytes.length;
    for (var i = 0; i < limit; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  /// MOBI/KF8 的标识在偏移 60 处。
  static bool _isMobi(Uint8List header) {
    if (header.length < 68) return false;
    const palmDb = 'BOOKMOBI';
    for (var i = 0; i < palmDb.length; i++) {
      if (header[60 + i] != palmDb.codeUnitAt(i)) return false;
    }
    return true;
  }
}
