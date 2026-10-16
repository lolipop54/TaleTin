// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'native_buffer.dart';
import 'src/third_party/scan.g.dart';
import 'text_decoder.dart';
import 'processing_features.dart';
import 'byte_processing.dart';
export 'text_decoder.dart';
export 'processing_features.dart';
export 'byte_processing.dart';

class NativeTxtLine {
  const NativeTxtLine(this.start, this.end, this.text, this.normalized);
  final int start, end;
  final String text, normalized;
}

/// One stream owns one native handle; callers close it on completion and cancellation.
class NativeTxtStream implements Finalizable {
  NativeTxtStream({
    String charset = 'UTF-8',
    int offset = 0,
    bool boundariesOnly = false,
    bool hashSource = false,
  }) : _handle = gt_txt_open(
         boundariesOnly ? 3 : nativeEncoding(charset),
         offset,
       ) {
    if (hashSource) gt_txt_hash_enable(_handle);
    _finalizer.attach(this, _handle, detach: _token, externalSize: 128 * 1024);
  }
  static final _finalizer = NativeFinalizer(Native.addressOf(gt_txt_close));
  final _token = Object();
  Pointer<Void> _handle;
  String get sourceDigest => withNativeResult(
    (output) => gt_txt_hash_result(_handle, output),
    hexDigest,
  );
  List<NativeTxtLine> feed(List<int> bytes, {bool finish = false}) {
    if (_handle == nullptr) throw StateError('TXT 扫描已关闭');
    return withNativeInput(
      bytes,
      (input, length) => withNativeResult(
        (output) => gt_txt_feed(_handle, input, length, finish ? 1 : 0, output),
        (bytes) {
          final data = ByteData.sublistView(bytes);
          final lines = <NativeTxtLine>[];
          var at = 0;
          while (at < bytes.length) {
            final start = data.getUint64(at, Endian.little),
                end = data.getUint64(at + 8, Endian.little);
            final raw = data.getUint32(at + 16, Endian.little),
                length = data.getUint32(at + 20, Endian.little);
            final units = data.getUint32(at + 24, Endian.little);
            at += 28;
            final text = nativeText(Uint8List.sublistView(bytes, at, at + raw));
            at += raw;
            final normalized = length == 0xffffffff
                ? text
                : nativeText(Uint8List.sublistView(bytes, at, at + length));
            if (length != 0xffffffff) at += length;
            if (normalized.length != units) {
              throw StateError('Rust UTF-16 长度不一致');
            }
            lines.add(NativeTxtLine(start, end, text, normalized));
          }
          return lines;
        },
      ),
    );
  }

  void close() {
    if (_handle != nullptr) {
      _finalizer.detach(_token);
      gt_txt_close(_handle);
      _handle = nullptr;
    }
  }
}

/// Dart keeps the existing book-resource URI rules; Rust owns parsing and conversion.
class NativeHtml implements Finalizable {
  /// Decode the original EPUB bytes in Rust, using the batch BOM rules.
  NativeHtml.bytes(Uint8List source)
    : _handle = withNativeInput(
        source,
        (p, n) =>
            gt_html_bytes(p, n, ProcessingFeatures.htmlAllocations ? 1 : 0),
      ) {
    _finalizer.attach(
      this,
      _handle,
      detach: _token,
      externalSize: source.length * 4,
    );
  }
  NativeHtml(String source)
    : _handle = withNativeInput(
        utf8.encode(source),
        (p, n) =>
            gt_html_options(p, n, ProcessingFeatures.htmlAllocations ? 1 : 0),
      ) {
    _finalizer.attach(
      this,
      _handle,
      detach: _token,
      externalSize: source.length * 4,
    );
  }
  static final _finalizer = NativeFinalizer(Native.addressOf(gt_html_close));
  final _token = Object();
  Pointer<Void> _handle;
  Map<String, dynamic> get references => withNativeResult(
    (o) => gt_html_refs(_handle, o),
    (b) => jsonDecode(utf8.decode(b)) as Map<String, dynamic>,
  );
  Map<String, dynamic> convert(
    Map<String, Object> metadata, {
    bool statisticsOnly = false,
    bool buildTextMap = false,
  }) => withNativeInput(
    utf8.encode(jsonEncode(metadata)),
    (input, length) => withNativeResult(
      (o) => gt_html_convert(
        _handle,
        input,
        length,
        (statisticsOnly ? 1 : 0) | (buildTextMap ? 2 : 0),
        o,
      ),
      (b) => jsonDecode(utf8.decode(b)) as Map<String, dynamic>,
    ),
  );
  void close() {
    if (_handle != nullptr) {
      _finalizer.detach(_token);
      gt_html_close(_handle);
      _handle = nullptr;
    }
  }
}

/// Up to four Rayon workers; output follows the original chapter order.
class NativeHtmlBatch implements Finalizable {
  NativeHtmlBatch(List<String> sources)
    : _handle = withNativeInput(
        utf8.encode(jsonEncode(sources)),
        (p, n) => gt_html_batch_options(
          p,
          n,
          ProcessingFeatures.htmlAllocations ? 1 : 0,
        ),
      ) {
    _finalizer.attach(
      this,
      _handle,
      detach: _token,
      externalSize: sources.fold<int>(0, (n, s) => n + s.length * 4),
    );
  }
  NativeHtmlBatch.bytes(List<Uint8List> sources)
    : _handle = withNativeInput(
        _pack(sources),
        (p, n) => gt_html_batch_bytes(
          p,
          n,
          ProcessingFeatures.htmlAllocations ? 1 : 0,
        ),
      ) {
    _finalizer.attach(
      this,
      _handle,
      detach: _token,
      externalSize: sources.fold<int>(0, (n, s) => n + s.length * 4),
    );
  }
  static Uint8List _pack(List<Uint8List> sources) {
    final packet = Uint8List(sources.fold<int>(0, (n, s) => n + 4 + s.length));
    final view = ByteData.sublistView(packet);
    var at = 0;
    for (final source in sources) {
      view.setUint32(at, source.length, Endian.little);
      at += 4;
      packet.setRange(at, at + source.length, source);
      at += source.length;
    }
    return packet;
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf(gt_html_batch_close),
  );
  final _token = Object();
  Pointer<Void> _handle;
  List<dynamic> get references => withNativeResult(
    (o) => gt_html_batch_refs(_handle, o),
    (b) => jsonDecode(utf8.decode(b)) as List,
  );
  Map<String, dynamic> get timings => withNativeResult(
    (o) => gt_html_batch_timings(_handle, o),
    (b) => jsonDecode(utf8.decode(b)) as Map<String, dynamic>,
  );
  List<dynamic> convert(
    List<Map<String, Object>> metadata, {
    bool statisticsOnly = true,
  }) => withNativeInput(
    utf8.encode(jsonEncode(metadata)),
    (input, length) => withNativeResult(
      (o) => gt_html_batch_convert_flags(
        _handle,
        input,
        length,
        statisticsOnly ? 1 : 0,
        o,
      ),
      (b) => jsonDecode(utf8.decode(b)) as List,
    ),
  );
  void close() {
    if (_handle != nullptr) {
      _finalizer.detach(_token);
      gt_html_batch_close(_handle);
      _handle = nullptr;
    }
  }
}
