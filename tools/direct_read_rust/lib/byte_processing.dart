// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'native_buffer.dart';
import 'src/third_party/scan.g.dart';

String hexDigest(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class NativeSha256 implements Finalizable {
  NativeSha256() : _handle = gt_hash_open() {
    _finalizer.attach(this, _handle, detach: _token, externalSize: 256);
  }
  static final _finalizer = NativeFinalizer(Native.addressOf(gt_hash_close));
  final _token = Object();
  Pointer<Void> _handle;
  void add(List<int> bytes) => _feed(bytes, false);
  String finish() => _feed(const [], true);
  String _feed(List<int> bytes, bool finish) => withNativeInput(
    bytes,
    (p, n) => withNativeResult(
      (o) => gt_hash_feed(_handle, p, n, finish ? 1 : 0, o),
      hexDigest,
    ),
  );
  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_token);
    gt_hash_close(_handle);
    _handle = nullptr;
  }
}

/// Use inside a worker isolate, keeping file reads asynchronous and cancellable.
Future<String> nativeFileDigest(String path) async {
  final hash = NativeSha256();
  try {
    await for (final bytes in File(path).openRead()) {
      hash.add(bytes);
    }
    return hash.finish();
  } finally {
    hash.close();
  }
}

class NativeInflater implements Finalizable {
  NativeInflater() : _handle = gt_inflate_open() {
    _finalizer.attach(this, _handle, detach: _token);
  }
  static final _finalizer = NativeFinalizer(Native.addressOf(gt_inflate_close));
  final _token = Object();
  Pointer<Void> _handle;
  Uint8List decode(List<int> bytes, int limit) =>
      withNativeInput(bytes, (p, n) {
        var status = 0;
        final result = withNativeResult(
          (o) => status = gt_inflate_decode(_handle, p, n, limit, o),
          Uint8List.fromList,
        );
        if (status == 2) throw const NativeInflateLimit();
        if (status != 0) throw const FormatException('DEFLATE 解压失败');
        return result;
      });
  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_token);
    gt_inflate_close(_handle);
    _handle = nullptr;
  }
}

class NativeInflateLimit implements Exception {
  const NativeInflateLimit();
}
