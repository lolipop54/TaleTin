import 'package:html/dom.dart';

/// 书内id是原始属性值，不是CSS选择器。纯数字、冒号和点号都必须精确匹配。
/// 目录、脚注和听书共用；重复id取文档中第一个，id优先于旧式a[name]。
class HtmlAnchorIndex {
  HtmlAnchorIndex(Iterable<Element> elements) {
    for (final element in elements) {
      final id = element.attributes['id'];
      if (id != null) _ids.putIfAbsent(id, () => element);
      final name = element.attributes['name'];
      if (name != null && (id != null || element.localName == 'a')) {
        _names.putIfAbsent(name, () => element);
      }
    }
  }

  final _ids = <String, Element>{}, _names = <String, Element>{};

  Element? find(String fragment) {
    Element? exact(String value) => _ids[value] ?? _names[value];
    final raw = exact(fragment);
    if (raw != null) return raw;
    if (fragment.contains('%')) {
      try {
        return exact(Uri.decodeComponent(fragment));
      } on FormatException {
        // 书内坏转义没有可解码的替代锚点。
      } on ArgumentError {
        // 不完整的百分号转义。
      }
    }
    return null;
  }
}
