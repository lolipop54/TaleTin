import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:direct_read_rust/direct_read_rust.dart';

/// Call from a background isolate. Both paths hash the original file bytes.
Future<String> sourceFileDigest(String path) async =>
    ProcessingFeatures.nativeHash
    ? nativeFileDigest(path)
    : (await sha256.bind(File(path).openRead()).first).toString();
