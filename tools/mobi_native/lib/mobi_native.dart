// Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/third_party/extract.g.dart';

export 'direct_mobi.dart';

/// Reconstructs an unencrypted MOBI/KF8 into an existing private staging folder.
/// The caller publishes the folder only after all content has been validated.
({int status, int version}) extractMobi(String source, String destination) {
  final input = source.toNativeUtf8();
  final output = destination.toNativeUtf8();
  final version = calloc<Int>();
  try {
    final status = gt_mobi_extract(
      input.cast<Char>(),
      output.cast<Char>(),
      version,
    );
    return (status: status, version: version.value);
  } finally {
    calloc.free(input);
    calloc.free(output);
    calloc.free(version);
  }
}
