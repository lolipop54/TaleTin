/// EPUB 嵌入字体的解混淆（IDPF 与 Adobe 两种算法，EPUB 3.3 字体混淆）。
///
/// 混淆不是加密：key 由书里的出版标识推导，不写在书里。两种算法都是
/// 「用 key 循环 XOR 文件开头若干字节」：
/// - IDPF（`http://www.idpf.org/2008/embedding`）：key = SHA-1(出版标识去空白)，
///   20 字节，XOR 前 1040 字节；
/// - Adobe（`http://ns.adobe.com/pdf/enc#RC`）：key = 出版标识里的 16 字节 UUID，
///   XOR 前 1024 字节。
///
/// 解出来的字节用字体魔数校验：对不上说明标识被改过（key 错），此时返回原始
/// 字节，因为「登记了混淆但其实没混淆」的书也真实存在。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'epub_archive.dart';

/// 混淆算法：key 来源与 XOR 字节数不同。
enum FontObfuscation {
  idpf('http://www.idpf.org/2008/embedding', 1040),
  adobe('http://ns.adobe.com/pdf/enc#RC', 1024);

  const FontObfuscation(this.algorithm, this.length);

  /// `EncryptionMethod@Algorithm` 的取值
  final String algorithm;

  /// 参与 XOR 的字节数
  final int length;

  static FontObfuscation? fromAlgorithm(String? algorithm) {
    for (final value in values) {
      if (value.algorithm == algorithm) return value;
    }
    return null;
  }
}

/// 一次解混淆的结果。
class DeobfuscatedFont {
  const DeobfuscatedFont({
    required this.bytes,
    required this.algorithm,
    required this.verified,
  });

  /// 可用字节：校验通过是解混淆后的，校验没过是原始字节（见库注释）
  final Uint8List bytes;

  /// 登记的算法；未登记为 null
  final FontObfuscation? algorithm;

  /// 解混淆后是否是合法字体（魔数校验）
  final bool verified;
}

/// 一本书的字体解混淆表：归档内路径 → 算法。
class EpubFontDeobfuscator {
  const EpubFontDeobfuscator._(this._algorithms);

  /// 空表：没有登记任何需要解混淆的字体
  static const EpubFontDeobfuscator empty =
      EpubFontDeobfuscator._(<String, FontObfuscation>{});

  final Map<String, FontObfuscation> _algorithms;

  /// 没有需要解混淆的字体
  bool get isEmpty => _algorithms.isEmpty;

  /// 登记的字体的数量
  int get length => _algorithms.length;

  /// 解析 `META-INF/encryption.xml`。
  ///
  /// [exists] 用于判断 URI 的两种可能基准（归档根 / OPF 目录）哪个真的命中
  /// —— 规范说相对归档根，但现实中两种写法都有。
  ///
  /// 文件损坏时返回空表：坏掉的加密声明不该拦住整本书的阅读。
  static EpubFontDeobfuscator parse(
    String encryptionXml, {
    required String opfPath,
    required bool Function(String entryPath) exists,
  }) {
    final algorithms = <String, FontObfuscation>{};
    final XmlDocument document;
    try {
      document = XmlDocument.parse(encryptionXml);
    } on XmlException {
      return EpubFontDeobfuscator._(algorithms);
    }
    for (final element in document.descendantElements) {
      if (element.name.local != 'EncryptedData') continue;
      String? algorithmName;
      String? uri;
      for (final child in element.descendantElements) {
        switch (child.name.local) {
          case 'EncryptionMethod':
            algorithmName ??= child.getAttribute('Algorithm');
          case 'CipherReference':
            uri ??= child.getAttribute('URI');
        }
      }
      final algorithm = FontObfuscation.fromAlgorithm(algorithmName);
      if (algorithm == null || uri == null) continue;
      final entryPath = _resolveCipherUri(uri, opfPath, exists);
      if (entryPath != null) algorithms[entryPath] = algorithm;
    }
    return EpubFontDeobfuscator._(algorithms);
  }

  /// 该条目是否登记过混淆
  FontObfuscation? algorithmOf(String entryPath) => _algorithms[entryPath];

  /// 解混淆一条字体条目。[identifier] 是书的出版标识（[EpubPackage.uniqueIdentifier]）。
  DeobfuscatedFont deobfuscate(
    String entryPath,
    Uint8List data,
    String identifier,
  ) {
    final algorithm = _algorithms[entryPath];
    if (algorithm == null) {
      return DeobfuscatedFont(bytes: data, algorithm: null, verified: false);
    }
    final key = _keyFor(algorithm, identifier);
    if (key == null || key.isEmpty) {
      return DeobfuscatedFont(bytes: data, algorithm: algorithm, verified: false);
    }
    final length = math.min(data.length, algorithm.length);
    final bytes = Uint8List.fromList(data);
    for (var i = 0; i < length; i++) {
      bytes[i] = data[i] ^ key[i % key.length];
    }
    if (!looksLikeFont(bytes)) {
      // key 不对：解出来还是垃圾，原始字节更有可能是「其实没混淆」的好字体
      return DeobfuscatedFont(
        bytes: data,
        algorithm: algorithm,
        verified: false,
      );
    }
    return DeobfuscatedFont(bytes: bytes, algorithm: algorithm, verified: true);
  }
}

/// 文件头是否是字体（TrueType / OpenType / WOFF / WOFF2）。
bool looksLikeFont(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final signature = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  return switch (signature) {
    0x00010000 => true, // TrueType
    0x4F54544F => true, // 'OTTO' CFF 轮廓的 OpenType
    0x74727565 => true, // 'true' 老式 TrueType
    0x74746366 => true, // 'ttcf' 字体集合
    0x774F4646 => true, // 'wOFF'
    0x774F4632 => true, // 'wOF2'
    _ => false,
  };
}

/// 按算法推导 key；取不到返回 null。
Uint8List? _keyFor(FontObfuscation algorithm, String identifier) {
  switch (algorithm) {
    case FontObfuscation.idpf:
      // 规范要求去掉出版标识里的一切空白后再哈希
      final normalized = identifier.replaceAll(RegExp(r'\s+'), '');
      if (normalized.isEmpty) return null;
      return Uint8List.fromList(sha1.convert(utf8.encode(normalized)).bytes);
    case FontObfuscation.adobe:
      final match = RegExp(
        r'([0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12})',
      ).firstMatch(identifier);
      if (match == null) return null;
      final hex = match.group(1)!.replaceAll('-', '');
      if (hex.length != 32) return null;
      final bytes = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return bytes;
  }
}

/// 解析 `CipherReference@URI`：先按归档根，再按 OPF 目录。
String? _resolveCipherUri(
  String uri,
  String opfPath,
  bool Function(String entryPath) exists,
) {
  final rootRelative = normalizeEntryPath(uri);
  if (rootRelative != null && exists(rootRelative)) return rootRelative;
  final opfRelative = resolveEntryPath(opfPath, uri);
  if (opfRelative != null && exists(opfRelative)) return opfRelative;
  return rootRelative ?? opfRelative;
}
