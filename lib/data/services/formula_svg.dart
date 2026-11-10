import 'dart:math' as math;

import 'package:xml/xml.dart';

/// flutter_tex 的行内输出可能包含多个 SVG 和 mjx-break。把片段按共同
/// 基线组合，避免只取第一个 SVG 丢失后面的等号、分式或运算项。
/// 当前 flutter_svg 已支持 text，中文说明直接保留，不再转成位图。
String prepareFormulaSvg(String output) {
  final wrapper = XmlDocument.parse('<formula>$output</formula>').rootElement;
  if (wrapper.descendants.whereType<XmlElement>().any(
    (e) => e.getAttribute('data-mml-node') == 'merror',
  )) {
    throw StateError('flutter_tex 无法解析此 MathML 结构');
  }
  final parts = wrapper.childElements.toList();
  if (parts.length == 1 && parts.single.name.local == 'svg') return output;

  var x = 0.0, baseline = 0.0, top = 0.0, bottom = 0.0, width = 0.0;
  final groups = <XmlElement>[];
  const spaces = [1, 111, 167, 222, 278, 333]; // MathJax 的 em/1000 间距表。
  for (final part in parts) {
    if (part.name.local == 'mjx-break') {
      if (part.getAttribute('newline') != null) {
        x = 0;
        baseline = bottom + 1000;
      } else {
        final size = int.tryParse(part.getAttribute('size') ?? '') ?? 0;
        x += spaces[size.clamp(0, spaces.length - 1)];
      }
      continue;
    }
    if (part.name.local != 'svg') continue;
    final view = part
        .getAttribute('viewBox')!
        .split(RegExp(r'[\s,]+'))
        .map(double.parse)
        .toList();
    top = math.min(top, baseline + view[1]);
    bottom = math.max(bottom, baseline + view[1] + view[3]);
    groups.add(
      XmlElement(XmlName('g'), [
        XmlAttribute(
          XmlName('transform'),
          'translate(${x - view[0]},$baseline)',
        ),
      ], part.children.map((node) => node.copy())),
    );
    x += view[2];
    width = math.max(width, x);
  }
  if (groups.isEmpty) throw StateError('flutter_tex 没有返回公式 SVG');
  return XmlElement(XmlName('svg'), [
    XmlAttribute(XmlName('xmlns'), 'http://www.w3.org/2000/svg'),
    XmlAttribute(XmlName('xmlns:xlink'), 'http://www.w3.org/1999/xlink'),
    XmlAttribute(XmlName('viewBox'), '0 $top $width ${bottom - top}'),
    XmlAttribute(XmlName('width'), '${width * .016}'),
    XmlAttribute(XmlName('height'), '${(bottom - top) * .016}'),
  ], groups).toXmlString();
}
