// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:ffi';
import 'dart:convert';
import 'dart:typed_data';

import 'native_buffer.dart';
import 'src/third_party/scan.g.dart';

/// One dictionary/cache per background original-book session; raw HTML bytes enter
/// and owned HTML bytes leave, without serializing the document through JSON.
class NativeOriginalHtml implements Finalizable {
  NativeOriginalHtml(Uint8List? dictionary)
    : _handle = withNativeInput(dictionary ?? Uint8List(0), gt_original_open) {
    _finalizer.attach(this, _handle, detach: _token);
  }
  static final _finalizer = NativeFinalizer(
    Native.addressOf(gt_original_close),
  );
  final _token = Object();
  Pointer<Void> _handle;
  Uint8List transform(Uint8List input) => withNativeInput(
    input,
    (p, n) => withNativeResult(
      (out) => gt_original_transform(_handle, p, n, out),
      Uint8List.fromList,
    ),
  );
  List<int> get stageTimesUs => withNativeResult(
    (out) => gt_original_timings(_handle, out),
    (bytes) => (jsonDecode(utf8.decode(bytes)) as List).cast<int>(),
  );
  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_token);
    gt_original_close(_handle);
    _handle = nullptr;
  }
}
