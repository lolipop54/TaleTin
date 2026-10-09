/// XHTML/DOM 取属性的统一入口。
///
/// `html` 包的属性表是 `Map<Object, String>`，键可能是普通 [String]，也可能是带
/// 命名空间的 [AttributeName]（`xlink:href`、`epub:type`、`xml:lang` 这类）。
/// 只按下标用字符串查**只能命中前者**，命名空间属性会静默查不到——曾经的后果是
/// SVG 封面（`<svg><image xlink:href="…"/></svg>`）整章解析成空页，简化排版下
/// 只剩一个章题。
library;

import 'package:html/dom.dart';

/// 取属性值；[name] 可以写限定名（`xlink:href`）或本地名（`href`）。
///
/// 找不到返回 null。
String? domAttribute(Element element, String name) {
  final direct = element.attributes[name];
  if (direct != null) return direct;
  for (final entry in element.attributes.entries) {
    final key = entry.key;
    if (key is! AttributeName) continue;
    final qualified = key.prefix == null ? key.name : '${key.prefix}:${key.name}';
    if (qualified == name || key.name == name) return entry.value;
  }
  return null;
}
