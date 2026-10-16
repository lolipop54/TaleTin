// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'src/third_party/scan.g.dart';

/// NativeFinalizer also releases allocations if isolate termination skips finally.
final class NativeAllocation implements Finalizable {
  NativeAllocation(this.pointer, int bytes) {
    _finalizer.attach(this, pointer, detach: _token, externalSize: bytes);
  }
  static final _finalizer = NativeFinalizer(calloc.nativeFree);
  final Pointer<Void> pointer;
  final _token = Object();
  void close() {
    _finalizer.detach(_token);
    calloc.free(pointer);
  }
}

T withNativeInput<T>(List<int> bytes, T Function(Pointer<Uint8>, int) action) {
  final input = calloc<Uint8>(bytes.length + 1);
  final allocation = NativeAllocation(input.cast(), bytes.length + 1);
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    return action(input, bytes.length);
  } finally {
    allocation.close();
  }
}

T withNativeResult<T>(
  void Function(Pointer<GtScanResult>) action,
  T Function(Uint8List) decode,
) {
  final output = calloc<GtScanResult>();
  final allocation = NativeAllocation(output.cast(), sizeOf<GtScanResult>());
  try {
    action(output);
    return decode(output.ref.data.asTypedList(output.ref.length));
  } finally {
    // The decoded values no longer refer to native data. Its owner frees the buffer.
    allocation.close();
  }
}

String nativeText(List<int> bytes) {
  final text = utf8.decode(bytes);
  return bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf
      ? '\ufeff$text'
      : text;
}
