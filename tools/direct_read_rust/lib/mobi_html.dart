// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:convert';
import 'dart:ffi';

import 'native_buffer.dart';
import 'src/third_party/scan.g.dart';

/// A single entry's HTML tree. The handle also owns its latest result so isolate
/// termination frees it even if Dart cannot execute its finally block.
class NativeMobiHtml implements Finalizable {
  NativeMobiHtml(String text)
    : _handle = withNativeInput(utf8.encode(text), gt_mobi_html_open) {
    _finalizer.attach(this, _handle, detach: _token);
  }
  static final _finalizer = NativeFinalizer(
    Native.addressOf(gt_mobi_html_close),
  );
  final _token = Object();
  Pointer<Void> _handle;
  List<List<dynamic>> get refs => withNativeResult(
    (out) => gt_mobi_html_refs(_handle, out),
    (bytes) => (jsonDecode(utf8.decode(bytes)) as List).cast<List<dynamic>>(),
  );
  String finish(List<List<Object>> edits) => withNativeInput(
    utf8.encode(jsonEncode(edits)),
    (input, length) => withNativeResult(
      (out) => gt_mobi_html_finish(_handle, input, length, out),
      utf8.decode,
    ),
  );
  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_token);
    gt_mobi_html_close(_handle);
    _handle = nullptr;
  }
}
