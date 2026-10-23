// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'native_buffer.dart';
import 'src/third_party/scan.g.dart';

/// 导入时的一小批HTML，复用至多四个Rust线程；输出始终保持输入顺序。
/// 句柄拥有所有树和结果，取消isolate时也由NativeFinalizer释放。
class NativeMobiHtmlBatch implements Finalizable {
  NativeMobiHtmlBatch(List<String> sources)
    : _handle = withNativeInput(_pack(sources), gt_mobi_batch_open) {
    _finalizer.attach(
      this,
      _handle,
      detach: _token,
      externalSize: sources.fold<int>(0, (n, s) => n + s.length * 4),
    );
  }
  static final _finalizer = NativeFinalizer(
    Native.addressOf(gt_mobi_batch_close),
  );
  final _token = Object();
  Pointer<Void> _handle;

  static Uint8List _pack(List<String> sources) {
    final bytes = [for (final source in sources) utf8.encode(source)];
    final packet = Uint8List(bytes.fold<int>(0, (n, s) => n + 4 + s.length));
    final view = ByteData.sublistView(packet);
    var at = 0;
    for (final source in bytes) {
      view.setUint32(at, source.length, Endian.little);
      packet.setAll(at + 4, source);
      at += 4 + source.length;
    }
    return packet;
  }

  List<List<List<dynamic>>> get refs => withNativeResult(
    (out) => gt_mobi_batch_refs(_handle, out),
    (bytes) => [
      for (final item in jsonDecode(utf8.decode(bytes)) as List)
        (item as List).cast<List<dynamic>>(),
    ],
  );

  List<Uint8List> finish(List<List<List<Object>>> edits) => withNativeInput(
    utf8.encode(jsonEncode(edits)),
    (input, length) => withNativeResult(
      (out) => gt_mobi_batch_finish(_handle, input, length, out),
      (packet) {
        final result = <Uint8List>[];
        final view = ByteData.sublistView(packet);
        var at = 0;
        while (at < packet.length) {
          final length = view.getUint32(at, Endian.little);
          // 结果不能引用句柄内存，下一次调用／关闭会释放原生缓冲。
          result.add(
            Uint8List.fromList(
              Uint8List.sublistView(packet, at + 4, at + 4 + length),
            ),
          );
          at += 4 + length;
        }
        return result;
      },
    ),
  );

  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_token);
    gt_mobi_batch_close(_handle);
    _handle = nullptr;
  }
}
