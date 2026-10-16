// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'native_buffer.dart';
import 'src/third_party/scan.g.dart';

const nativeCharsets = [
  'UTF-8',
  'UTF-16LE',
  'UTF-16BE',
  'GB18030',
  'GBK',
  'GB2312',
  'Big5',
  'Shift_JIS',
  'EUC-KR',
  'ISO-8859-1',
  'windows-1252',
];

int nativeEncoding(String charset) => switch (charset.toUpperCase()) {
  'UTF-8' || 'UTF8' => 0,
  'UTF-16LE' => 1,
  'UTF-16BE' => 2,
  'GB18030' => 4,
  'GBK' || 'GB2312' => 5,
  'BIG5' => 6,
  'SHIFT_JIS' => 7,
  'EUC-KR' => 8,
  'ISO-8859-1' => 9,
  'WINDOWS-1252' => 10,
  _ => throw UnsupportedError('不支持的字符集：$charset'),
};

/// Decoder state retains incomplete characters across file chunks.
final class NativeTextDecoder implements Finalizable {
  NativeTextDecoder(String charset)
    : _handle = gt_text_open(nativeEncoding(charset)) {
    _finalizer.attach(this, _handle, detach: _token, externalSize: 128 * 1024);
  }
  static final _finalizer = NativeFinalizer(Native.addressOf(gt_text_close));
  final _token = Object();
  Pointer<Void> _handle;

  Uint8List feed(List<int> bytes, {bool finish = false}) {
    if (_handle == nullptr) throw StateError('文本解码已关闭');
    return withNativeInput(
      bytes,
      (input, length) => withNativeResult(
        (output) =>
            gt_text_feed(_handle, input, length, finish ? 1 : 0, output),
        Uint8List.fromList,
      ),
    );
  }

  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_token);
    gt_text_close(_handle);
    _handle = nullptr;
  }
}

String decodeNativeText(
  List<int> bytes,
  String charset, {
  bool stripBom = false,
}) {
  final decoder = NativeTextDecoder(charset);
  try {
    final text = nativeText(decoder.feed(bytes, finish: true));
    return stripBom && text.startsWith('\ufeff') ? text.substring(1) : text;
  } finally {
    decoder.close();
  }
}

/// Call from a worker isolate. Output keeps BOM, matching Android file transcoding.
Future<void> transcodeNativeFile(
  String source,
  String target,
  String charset,
) async {
  final decoder = NativeTextDecoder(charset);
  final output = File(target).openWrite();
  try {
    await for (final bytes in File(source).openRead()) {
      output.add(decoder.feed(bytes));
    }
    output.add(decoder.feed(const [], finish: true));
    await output.flush();
  } finally {
    decoder.close();
    await output.close();
  }
}
