/// 图片尺寸嗅探（设计文档 6.3）。
///
/// 位图按文件头解析 PNG/JPEG/GIF/WebP/BMP 的宽高；SVG 读根元素声明的
/// width/height；无法判断时按 1:1 兜底，界面按内容宽度等比缩放。
library;

import 'dart:typed_data';

import 'package:xml/xml.dart';

class ImageSize {
  const ImageSize(this.width, this.height);
  final int width;
  final int height;
}

/// 按文件头判断图片格式与尺寸；不是已知位图格式时返回 null。
ImageSize? sniffBitmapSize(Uint8List bytes) {
  if (bytes.length < 16) return null;
  if (_startsWith(bytes, const [0x89, 0x50, 0x4E, 0x47])) {
    return _pngSize(bytes);
  }
  if (_startsWith(bytes, const [0xFF, 0xD8])) {
    return _jpegSize(bytes);
  }
  if (_startsWith(bytes, const [0x47, 0x49, 0x46, 0x38])) {
    return _gifSize(bytes);
  }
  if (_startsWith(bytes, const [0x42, 0x4D])) {
    return _bmpSize(bytes);
  }
  if (_startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      bytes.length >= 16 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return _webpSize(bytes);
  }
  return null;
}

/// SVG：按根元素 width/height 声明；只有 viewBox 时用 viewBox 的宽高比。
ImageSize? sniffSvgSize(Uint8List bytes) {
  final head = String.fromCharCodes(
    bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes,
  );
  if (!head.contains('<svg')) return null;
  try {
    // 只读取完整的根起始标签。截断整个 SVG 再按 XML 解析，会因缺少闭合
    // 标签失败，把较大的矢量图误记成 1×1，简化排版中几乎看不见。
    final opening = RegExp(r'<svg\b[^>]*>', caseSensitive: false).firstMatch(head);
    if (opening == null) return null;
    final root = opening.group(0)!.replaceFirst(RegExp(r'/?>$'), '/>');
    final document = XmlDocument.parse(root);
    final svg = document.rootElement;
    final width = _parseLength(svg.getAttribute('width'));
    final height = _parseLength(svg.getAttribute('height'));
    if (width != null && height != null && width > 0 && height > 0) {
      return ImageSize(width, height);
    }
    final viewBox = svg.getAttribute('viewBox');
    if (viewBox != null) {
      final parts = viewBox
          .split(RegExp(r'[\s,]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.length == 4) {
        final w = double.tryParse(parts[2]);
        final h = double.tryParse(parts[3]);
        if (w != null && h != null && w > 0 && h > 0) {
          return ImageSize(w.round(), h.round());
        }
      }
    }
  } catch (_) {
    // SVG 头部不完整或格式异常：交给 1:1 兜底
  }
  return null;
}

/// 统一入口：先按位图嗅探，再试 SVG，最后 1:1。
ImageSize sniffImageSize(Uint8List bytes) {
  final bitmap = sniffBitmapSize(bytes);
  if (bitmap != null) return bitmap;
  final svg = sniffSvgSize(bytes);
  if (svg != null) return svg;
  return const ImageSize(1, 1);
}

ImageSize _pngSize(Uint8List b) {
  if (b.length < 24) return const ImageSize(1, 1);
  return ImageSize(_be32(b, 16), _be32(b, 20));
}

ImageSize _gifSize(Uint8List b) {
  if (b.length < 10) return const ImageSize(1, 1);
  return ImageSize(_le16(b, 6), _le16(b, 8));
}

ImageSize _bmpSize(Uint8List b) {
  if (b.length < 26) return const ImageSize(1, 1);
  return ImageSize(_le32(b, 18).abs(), _le32(b, 22).abs());
}

ImageSize _jpegSize(Uint8List b) {
  var index = 2;
  while (index + 9 < b.length) {
    if (b[index] != 0xFF) {
      index++;
      continue;
    }
    final marker = b[index + 1];
    // SOF0–SOF15（除 DHT/DAC/RSTn）携带尺寸
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      return ImageSize(_be16(b, index + 7), _be16(b, index + 5));
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      index += 2;
      continue;
    }
    final length = _be16(b, index + 2);
    if (length <= 0) break;
    index += 2 + length;
  }
  return const ImageSize(1, 1);
}

ImageSize _webpSize(Uint8List b) {
  final fourcc = String.fromCharCodes(b.sublist(12, 16));
  switch (fourcc) {
    case 'VP8 ':
      if (b.length < 30) break;
      return ImageSize(_le16(b, 26) & 0x3FFF, _le16(b, 28) & 0x3FFF);
    case 'VP8L':
      if (b.length < 25) break;
      final bits = _le32(b, 21);
      return ImageSize((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8X':
      if (b.length < 30) break;
      return ImageSize(_le24(b, 24) + 1, _le24(b, 27) + 1);
  }
  return const ImageSize(1, 1);
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

int _be16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

int _be32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _le16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

int _le24(Uint8List b, int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);

int _le32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

int? _parseLength(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^\s*([0-9]*\.?[0-9]+)').firstMatch(value);
  if (match == null) return null;
  final parsed = double.tryParse(match.group(1)!);
  if (parsed == null || parsed <= 0) return null;
  return parsed.round();
}
