import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final _unsupported = RegExp(r'[<>:"|?*\x00-\x1f]');
final _device = RegExp(
  r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
  caseSensitive: false,
);
const _encodedDirectory = '_zip_entry_';

/// ZIP 内路径用于查找正文和资源。仅在落盘时换掉 Windows 不接受的名称。
/// 各平台用同一映射，备份从安卓搬到 Windows 时仍能找到图片。
String publicationCachePath(String entry) {
  final parts = entry.split('/');
  if (parts.first.toLowerCase() != _encodedDirectory &&
      parts.every(
        (part) =>
            !_unsupported.hasMatch(part) &&
            !_device.hasMatch(part) &&
            !part.endsWith('.') &&
            !part.endsWith(' '),
      )) {
    return entry;
  }
  final digest = sha256.convert(utf8.encode(entry));
  final extension = p.posix.extension(entry);
  final suffix = RegExp(r'^\.[a-zA-Z0-9]{1,12}$').hasMatch(extension)
      ? extension
      : '';
  return '$_encodedDirectory/$digest$suffix';
}
