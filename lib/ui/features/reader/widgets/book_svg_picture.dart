import 'dart:io';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:xml/xml.dart';

Future<PictureInfo> loadBookSvg(File file, {SvgTheme? theme}) async {
  try {
    final picture = await vg.loadPicture(
      SvgFileLoader(file, theme: theme),
      null,
    );
    if (picture.size.isFinite && !picture.size.isEmpty) return picture;
    picture.picture.dispose();
    throw const FormatException('SVG has no intrinsic size');
  } catch (_) {
    // 某些 EPUB 有只有根标签的 SVG，且百分比宽高无法用于独立解码。
    // 它没有图形可画，用透明画面交接；损坏或缺失的资源仍走失败处理。
    if (!await _isEmptySvg(file)) rethrow;
    return vg.loadPicture(
      const SvgStringLoader(
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'width="1" height="1"></svg>',
      ),
      null,
    );
  }
}

Future<bool> _isEmptySvg(File file) async {
  try {
    final root = XmlDocument.parse(await file.readAsString()).rootElement;
    return root.name.local == 'svg' &&
        root.childElements.isEmpty &&
        root.innerText.trim().isEmpty;
  } on FormatException {
    return false;
  } on XmlException {
    return false;
  } on FileSystemException {
    return false;
  }
}
