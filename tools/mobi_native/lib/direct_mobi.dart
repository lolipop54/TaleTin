// Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/third_party/extract.g.dart';

/// Range reader for one worker isolate. Headers and HUFF/CDIC dictionaries stay
/// resident; a requested text/resource record is released after its result copy.
class DirectMobi implements Finalizable {
  DirectMobi(String source, {bool sequentialRead = false}) {
    final path = source.toNativeUtf8();
    final status = calloc<Int>();
    try {
      _handle = gt_mobi_open(path.cast(), status);
      if (_handle == nullptr) throw MobiReadFailure(status.value);
      _finalizer.attach(this, _handle.cast(), detach: _token);
      if (sequentialRead) gt_mobi_buffer_input(_handle);
    } finally {
      calloc.free(path);
      calloc.free(status);
    }
  }

  static final _finalizer = NativeFinalizer(Native.addressOf(gt_mobi_close));
  final _token = Object();
  Pointer<gt_mobi_session> _handle = nullptr;

  int _info(int field) {
    if (_handle == nullptr) throw StateError('MOBI reader is closed');
    return gt_mobi_info(_handle, field);
  }

  int get recordCount => _info(0);
  int get firstTextRecord => _info(1);
  int get textRecordCount => _info(2);
  int get firstResourceRecord => _info(3);
  int get version => _info(4);
  int get encoding => _info(5);
  int get sourceBytes => _info(6);
  int get bytesRead => _info(7);
  int get recordsDecoded => _info(8);
  int get retainedRecordBytes => _info(9);
  int get inputWindowFills => _info(11);
  int get inputWindowBytes => _info(12);

  /// Each batch yields to worker commands; no whole decoded book is retained.
  Future<void> buildIndex({
    required bool Function() isCancelled,
    void Function(double)? onProgress,
  }) async {
    final count = textRecordCount;
    for (var at = 0; at < count; at += 128) {
      _checkStatus(gt_mobi_scan(_handle, 128));
      onProgress?.call(.25 * ((at + 128) / count).clamp(0, 1));
      await Future<void>.delayed(Duration.zero);
      if (isCancelled()) throw const MobiReadFailure(7);
    }
    _checkStatus(gt_mobi_structure(_handle));
    var entries = gt_mobi_entries(_handle);
    for (var i = 0; i < entries; i++) {
      _checkStatus(gt_mobi_anchors(_handle, i));
      onProgress?.call(.25 + .3 * (i + 1) / entries);
      if (i % 16 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled()) throw const MobiReadFailure(7);
      }
    }
    _checkStatus(gt_mobi_metadata(_handle));
    entries = gt_mobi_entries(_handle);
    for (var i = 0; i < entries; i++) {
      _checkStatus(gt_mobi_links(_handle, i));
      onProgress?.call(.55 + .45 * (i + 1) / entries);
      if (i % 16 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled()) throw const MobiReadFailure(7);
      }
    }
  }

  List<MobiEntry> get entries => [
    for (var i = 0; i < gt_mobi_entries(_handle); i++) _entry(i),
  ];

  MobiEntry _entry(int index) {
    _checkStatus(gt_mobi_entry_info(_handle, index));
    final values = String.fromCharCodes(_result()).split('\n');
    return MobiEntry(
      index,
      values[0],
      int.parse(values[1]),
      int.parse(values[2]),
    );
  }

  Uint8List exportIndex() {
    _checkStatus(gt_mobi_index_export(_handle));
    return _result();
  }

  void importIndex(Uint8List bytes) {
    final input = calloc<Uint8>(bytes.length);
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      _checkStatus(gt_mobi_index_import(_handle, input.cast(), bytes.length));
    } finally {
      calloc.free(input);
    }
  }

  Uint8List readEntry(MobiEntry entry, {int offset = 0, int? length}) {
    _checkStatus(
      gt_mobi_entry_read(
        _handle,
        entry.index,
        offset,
        length ?? entry.size - offset,
        1,
      ),
    );
    return _result();
  }

  Iterable<Uint8List> entryChunks(MobiEntry entry) sync* {
    for (var at = 0; at < entry.size; at += 32768) {
      final count = (entry.size - at).clamp(0, 32768);
      yield readEntry(entry, offset: at, length: count);
    }
  }

  void _checkStatus(int status) {
    if (status != 0) throw MobiReadFailure(status);
  }

  Uint8List _result() => Uint8List.fromList(
    gt_mobi_result(_handle)
        .cast<Uint8>()
        .asTypedList(gt_mobi_result_size(_handle)),
  );

  int recordOffset(int number) {
    _checkRecord(number);
    return gt_mobi_record_offset(_handle, number);
  }

  int recordSize(int number) {
    _checkRecord(number);
    return gt_mobi_record_size(_handle, number);
  }

  Uint8List readRecord(int number) => _read(number, 0);
  Uint8List decodeTextRecord(int number) => _read(number, 1);
  Uint8List readResource(int number) => _read(number, 2);

  Uint8List _read(int number, int mode) {
    _checkRecord(number);
    final status = gt_mobi_record(_handle, number, mode);
    if (status != 0) throw MobiReadFailure(status);
    final length = gt_mobi_result_size(_handle);
    return Uint8List.fromList(
      gt_mobi_result(_handle).cast<Uint8>().asTypedList(length),
    );
  }

  void _checkRecord(int number) {
    if (number < 0 || number >= recordCount) {
      throw RangeError.range(number, 0, recordCount - 1, 'number');
    }
  }

  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_token);
    gt_mobi_close(_handle.cast());
    _handle = nullptr;
  }
}

class MobiEntry {
  const MobiEntry(this.index, this.name, this.size, this.kind);
  final int index, size, kind;
  final String name;
}

class MobiReadFailure implements Exception {
  const MobiReadFailure(this.status);
  final int status;
  @override
  String toString() => 'MOBI read failed ($status)';
}
