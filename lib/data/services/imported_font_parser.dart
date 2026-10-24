import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../domain/models/imported_font.dart';

typedef ParsedFontFace = ({ImportedFontFace face, Uint8List bytes});

/// 只解析 OpenType 的目录、名称和字重；实际字形还要由平台解码器验证。
/// TTC 的表偏移相对整个集合，必须重建独立 sfnt，不能简单截取文件尾部。
List<ParsedFontFace> parseImportedFonts(Uint8List bytes, String fallbackName) {
  final input = _FontData(bytes);
  final offsets = <int>[];
  if (input.tag(0) == 'ttcf') {
    final count = input.u32(8);
    if (count == 0 || count > 256) throw const FormatException('字体集合数量无效');
    input.check(12, count * 4);
    for (var i = 0; i < count; i++) {
      offsets.add(input.u32(12 + i * 4));
    }
  } else {
    offsets.add(0);
  }
  final result = <ParsedFontFace>[];
  var extractedBytes = 0;
  for (final offset in offsets) {
    final signature = input.u32(offset);
    if (signature != 0x00010000 &&
        signature != 0x4f54544f &&
        signature != 0x74727565) {
      throw const FormatException('不是支持的 TTF、OTF 或 TTC 字体');
    }
    final count = input.u16(offset + 4);
    if (count == 0 || count > 256) throw const FormatException('字体表数量无效');
    input.check(offset + 12, count * 16);
    final tables = <String, ({int offset, int length})>{};
    for (var i = 0; i < count; i++) {
      final at = offset + 12 + i * 16;
      final tag = input.tag(at),
          start = input.u32(at + 8),
          length = input.u32(at + 12);
      input.check(start, length);
      if (tables.containsKey(tag)) throw const FormatException('字体存在重复数据表');
      tables[tag] = (offset: start, length: length);
    }
    for (final tag in ['head', 'maxp', 'cmap', 'hhea', 'hmtx', 'name']) {
      if (!tables.containsKey(tag)) throw FormatException('字体缺少 $tag 数据表');
    }
    if (!(tables.containsKey('glyf') && tables.containsKey('loca')) &&
        !tables.containsKey('CFF ') &&
        !tables.containsKey('CFF2')) {
      throw const FormatException('字体缺少支持的轮廓数据');
    }
    final head = tables['head']!;
    if (head.length < 54 || input.u32(head.offset + 12) != 0x5f0f3cf5) {
      throw const FormatException('字体头损坏');
    }
    final nameTable = tables['name']!;
    final name =
        _familyName(
          _FontData(
            Uint8List.sublistView(
              bytes,
              nameTable.offset,
              nameTable.offset + nameTable.length,
            ),
          ),
        ) ??
        fallbackName;
    var weight = 400, italic = (input.u16(head.offset + 44) & 2) != 0;
    if (tables['OS/2'] case final os?) {
      if (os.length < 8) throw const FormatException('字体字重信息损坏');
      weight = input.u16(os.offset + 4).clamp(1, 1000);
      if (os.length >= 64) italic = (input.u16(os.offset + 62) & 1) != 0;
    }
    var minWeight = weight, maxWeight = weight;
    if (tables['fvar'] case final table?) {
      final data = _FontData(
        Uint8List.sublistView(bytes, table.offset, table.offset + table.length),
      );
      final axes = data.u16(4),
          axesCount = data.u16(8),
          axisSize = data.u16(10);
      if (axisSize < 20) throw const FormatException('可变字体轴信息损坏');
      data.check(axes, axesCount * axisSize);
      for (var i = 0; i < axesCount; i++) {
        final at = axes + i * axisSize;
        if (data.tag(at) == 'wght') {
          minWeight = (data.i32(at + 4) / 65536).round().clamp(1, 1000);
          maxWeight = (data.i32(at + 12) / 65536).round().clamp(1, 1000);
          if (minWeight > maxWeight) throw const FormatException('可变字体字重范围无效');
        }
      }
    }
    // 原独立字体保持字节不变；集合字体剔除失效的数字签名并重算校验和。
    final extracted = offsets.length == 1 && offset == 0
        ? bytes
        : _extract(input, signature, tables);
    extractedBytes += extracted.length;
    if (extractedBytes > 256 * 1024 * 1024) {
      throw const FormatException('字体集合展开后超过 256 MiB');
    }
    final digest = sha256.convert(extracted).toString();
    result.add((
      face: ImportedFontFace(
        digest: digest,
        familyName: name,
        minWeight: minWeight,
        maxWeight: maxWeight,
        italic: italic,
      ),
      bytes: extracted,
    ));
  }
  return result;
}

String? _familyName(_FontData data) {
  final count = data.u16(2), storage = data.u16(4);
  data.check(6, count * 12);
  String? best;
  var bestScore = -1;
  for (var i = 0; i < count; i++) {
    final at = 6 + i * 12,
        platform = data.u16(at),
        language = data.u16(at + 4),
        id = data.u16(at + 6);
    if (id != 1 && id != 16) continue;
    final length = data.u16(at + 8), offset = storage + data.u16(at + 10);
    data.check(offset, length);
    final raw = Uint8List.sublistView(data.bytes, offset, offset + length);
    String text;
    if (platform == 0 || platform == 3) {
      if (length.isOdd) continue;
      text = String.fromCharCodes([
        for (var j = 0; j < length; j += 2) (raw[j] << 8) | raw[j + 1],
      ]);
    } else if (platform == 1 && raw.every((b) => b < 128)) {
      text = ascii.decode(raw);
    } else {
      continue;
    }
    text = text.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    final score =
        (id == 16 ? 100 : 0) +
        (language == 0x804
            ? 30
            : language == 0x409
            ? 20
            : 0) +
        (platform == 3 ? 2 : 0);
    if (text.isNotEmpty && score > bestScore) {
      best = text;
      bestScore = score;
    }
  }
  return best;
}

Uint8List _extract(
  _FontData input,
  int signature,
  Map<String, ({int offset, int length})> tables,
) {
  final tags = tables.keys.where((t) => t != 'DSIG').toList()..sort();
  var length = 12 + tags.length * 16;
  for (final tag in tags) {
    length += (tables[tag]!.length + 3) & ~3;
  }
  if (length > 64 * 1024 * 1024) throw const FormatException('单个字体超过 64 MiB');
  final bytes = Uint8List(length), data = ByteData.sublistView(bytes);
  data.setUint32(0, signature);
  data.setUint16(4, tags.length);
  var power = 1, exponent = 0;
  while (power * 2 <= tags.length) {
    power *= 2;
    exponent++;
  }
  data.setUint16(6, power * 16);
  data.setUint16(8, exponent);
  data.setUint16(10, tags.length * 16 - power * 16);
  var cursor = 12 + tags.length * 16, head = 0;
  for (var i = 0; i < tags.length; i++) {
    final tag = tags[i], table = tables[tag]!, at = 12 + i * 16;
    bytes.setRange(at, at + 4, tag.codeUnits);
    bytes.setRange(cursor, cursor + table.length, input.bytes, table.offset);
    if (tag == 'head') {
      head = cursor;
      data.setUint32(cursor + 8, 0);
    }
    data.setUint32(at + 4, _checksum(bytes, cursor, table.length));
    data.setUint32(at + 8, cursor);
    data.setUint32(at + 12, table.length);
    cursor += (table.length + 3) & ~3;
  }
  data.setUint32(
    head + 8,
    (0xb1b0afba - _checksum(bytes, 0, bytes.length)) & 0xffffffff,
  );
  return bytes;
}

int _checksum(Uint8List bytes, int offset, int length) {
  var sum = 0;
  for (var i = 0; i < length; i += 4) {
    var word = 0;
    for (var j = 0; j < 4; j++) {
      word = (word << 8) | (i + j < length ? bytes[offset + i + j] : 0);
    }
    sum = (sum + word) & 0xffffffff;
  }
  return sum;
}

class _FontData {
  _FontData(this.bytes) : data = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData data;
  void check(int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw const FormatException('字体文件不完整或偏移越界');
    }
  }

  int u16(int at) {
    check(at, 2);
    return data.getUint16(at);
  }

  int u32(int at) {
    check(at, 4);
    return data.getUint32(at);
  }

  int i32(int at) {
    check(at, 4);
    return data.getInt32(at);
  }

  String tag(int at) {
    check(at, 4);
    return String.fromCharCodes(bytes.sublist(at, at + 4));
  }
}
