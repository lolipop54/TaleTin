/// XHTML 净化：剥掉一切可执行内容，保留结构与样式。
///
/// 安全红线（设计文档 6.1「EPUB 脚本不执行」）：内容在进入 WebView **之前**
/// 就把脚本、事件属性、框架标签清掉，浏览器根本没有执行机会。
///
/// 保留的是原书排版模式要还原的那部分：`<style>`、class、行内 style、
/// `link rel=stylesheet`、图片与字体引用，全部原样。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';

/// 直接删除的标签：脚本、框架、内嵌对象，以及会改变相对路径基准的 `<base>`。
/// `meta refresh` 按属性判定（见下），`noscript` 一起删：它的内容是用来
/// 替代脚本的，脚本都没了留着只会显示「请启用 JavaScript」这类话。
const _blockedTags = {
  'script',
  'noscript',
  'iframe',
  'frame',
  'frameset',
  'embed',
  'object',
  'applet',
  'base',
};

/// 可能带 URL 的属性：值为脚本协议或 `data:text/html` 时改写掉。
const _urlAttributes = {
  'href',
  'src',
  'xlink:href',
  'action',
  'formaction',
  'background',
  'poster',
};

/// `<?xml-stylesheet?>` 处理指令里的样式引用。
///
/// EPUB 2 常用它引用样式表，而 HTML 解析器会把处理指令当注释丢掉——不先提取
/// 出来补成 `<link>`，这些书的样式会整个消失。
final _xmlStylesheet = RegExp(
  r'''<\?xml-stylesheet[^>]*?href\s*=\s*["']([^"']+)["'][^>]*?\?>''',
  caseSensitive: false,
);

/// 净化结果：拿去做 WebView 文档的 HTML，以及一份「改了什么」的说明。
class SanitizeResult {
  const SanitizeResult({
    required this.html,
    this.removedTags = 0,
    this.rewrittenUrls = 0,
    this.restoredStylesheets = const [],
    this.degraded = false,
  });

  final String html;

  /// 删掉的标签数（脚本、框架、base 等）
  final int removedTags;

  /// 改写成 `#` 的脚本协议链接数
  final int rewrittenUrls;

  /// 从 `<?xml-stylesheet?>` 补回来的样式引用
  final List<String> restoredStylesheets;

  /// 是否走了降级路径（文档嵌套过深、DOM 解析栈溢出，改用正则剥离）
  final bool degraded;
}

/// 深嵌套文档的兜底净化：不做 DOM 解析，只用正则剥掉可执行内容。
///
/// 触发条件见 [EpubSanitizer.sanitize]：漫画/图文类 EPUB 的 XHTML 嵌套可以深到
/// `html` 包（递归下降）解析栈溢出。浏览器自己的解析器是迭代的、不怕深，所以这里
/// 保持结构原样，只做安全剥离——**宁可多删，不能漏**。
class _PatternSanitizer {
  /// `<script>…</script>`（找不到闭合就一直删到文末：宁可少显示，不可留脚本）
  static final _script = RegExp(r'<script\b[\s\S]*?(?:</script\s*>|$)',
      caseSensitive: false);

  /// 会加载并执行外部内容的框架类标签（含内容）
  static final _framed = RegExp(
    r'<(iframe|frame|frameset|embed|object|applet|noscript)\b[\s\S]*?(?:</\1\s*>|$)',
    caseSensitive: false,
  );

  /// 自闭合或未配对的框架类标签
  static final _framedVoid = RegExp(
    r'''(?:iframe|frame|frameset|embed|object|applet|base|link\s+rel\s*=\s*["']?preload)\b[^>]*>''',
    caseSensitive: false,
  );

  /// `on*` 事件属性（单/双引号与无引号都覆盖）
  static final _eventAttr =
      RegExp(r'''\son[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)''', caseSensitive: false);

  /// 脚本协议：把协议名换掉，浏览器就当普通未知协议处理。
  /// `data:` 只挡 `data:text/html`——`data:image/...` 是合法的内联图片，不能误伤。
  static final _scriptProtocol =
      RegExp(r'\b(javascript|vbscript)\s*:', caseSensitive: false);
  static final _htmlDataProtocol =
      RegExp(r'\bdata\s*:\s*text/html', caseSensitive: false);

  /// `<meta http-equiv=refresh>`
  static final _metaRefresh = RegExp(
    r'''<meta\b[^>]*http-equiv\s*=\s*["']?\s*refresh["']?[^>]*>''',
    caseSensitive: false,
  );

  /// `<?xml-stylesheet?>` 处理指令（要保留成 link，否则丢样式）
  static final _xmlStylesheet = RegExp(
    r'''<\?xml-stylesheet[^>]*?href\s*=\s*["']([^"']+)["'][^>]*?\?>''',
    caseSensitive: false,
  );

  static SanitizeResult run(String source) {
    final stylesheets = [
      for (final match in _xmlStylesheet.allMatches(source)) match.group(1)!,
    ];
    var text = source;
    text = text.replaceAll(_script, '');
    text = text.replaceAll(_framed, '');
    text = text.replaceAll(_framedVoid, '');
    text = text.replaceAll(_metaRefresh, '');
    text = text.replaceAll(_eventAttr, '');
    // `javascript:` → `blocked-js:`（保留原样会执行，改协议名最省事且不会漏）
    text = text.replaceAll(_scriptProtocol, 'blocked-js:');
    text = text.replaceAll(_htmlDataProtocol, 'blocked-data:text/html');
    if (stylesheets.isNotEmpty) {
      final links = stylesheets
          .map((href) =>
              '<link rel="stylesheet" type="text/css" href="${_escapeAttribute(href)}"/>')
          .join();
      final headEnd = text.toLowerCase().indexOf('</head>');
      text = headEnd < 0
          ? links + text
          : text.replaceRange(headEnd, headEnd, links);
    }
    return SanitizeResult(
      html: text,
      restoredStylesheets: stylesheets,
      degraded: true,
    );
  }
}

class EpubSanitizer {
  /// 净化 XHTML，返回可交给 WebView 的 HTML 文档。
  ///
  /// 解析用宽松的 HTML 解析器：真实 EPUB 里有大量不是合法 XML 的 XHTML，
  /// 严格解析会直接失败。代价是 XHTML 的 `<div/>` 这类自闭合写法会被当作开标签
  /// （已知限制，见 `docs/原书排版模式实现计划.md` 第 8 节）。
  ///
  /// **深嵌套文档会退回正则净化**：漫画/图文类书籍的 XHTML 嵌套深到让递归下降的
  /// 解析器栈溢出（真机实测，溢出发生在 WebView 的资源拦截里，表现为主文档
  /// 加载失败）。这种情况保持结构原样、只用正则剥掉可执行内容——浏览器自己的
  /// 解析器是迭代的，不怕深嵌套。
  static SanitizeResult sanitize(String source) {
    try {
      return _sanitizeWithDom(source);
    } on StackOverflowError {
      return _PatternSanitizer.run(source);
    }
  }

  /// 深嵌套文档的兜底净化（正则剥离，不解析 DOM）。
  /// 单独暴露出来便于直接测试这条路径。
  @visibleForTesting
  static SanitizeResult sanitizeByPattern(String source) =>
      _PatternSanitizer.run(source);

  static SanitizeResult _sanitizeWithDom(String source) {
    final stylesheets = [
      for (final match in _xmlStylesheet.allMatches(source)) match.group(1)!,
    ];
    final document = html_parser.parse(source);

    final removed = document.querySelectorAll(_blockedTags.join(',')).length;
    for (final element in document.querySelectorAll(_blockedTags.join(','))) {
      element.remove();
    }

    // meta refresh 会自动跳转（书里少见，但属于「带着你走」的行为）
    for (final meta in document.querySelectorAll('meta')) {
      final httpEquiv =
          (meta.attributes['http-equiv'] ?? meta.attributes['http_equiv'] ?? '')
              .toLowerCase();
      if (httpEquiv == 'refresh') meta.remove();
    }

    var rewritten = 0;
    for (final element in document.querySelectorAll('*')) {
      // 遍历中会删属性，先复制一份键
      final entries = Map<Object, String>.from(element.attributes).entries.toList();
      for (final entry in entries) {
        final name = _attributeName(entry.key).toLowerCase();
        if (name.startsWith('on')) {
          element.attributes.remove(entry.key);
          continue;
        }
        if (_urlAttributes.contains(name) && _isScriptUrl(entry.value)) {
          element.attributes[entry.key] = '#';
          rewritten++;
        }
      }
    }

    _restoreStylesheets(document, stylesheets);

    return SanitizeResult(
      html: document.outerHtml,
      removedTags: removed,
      rewrittenUrls: rewritten,
      restoredStylesheets: stylesheets,
    );
  }

  /// 把 `<?xml-stylesheet?>` 补成 head 里的 `<link>`。
  ///
  /// 插在 head 最前：处理指令在文档里就位于最前面，样式优先级要保序。
  static void _restoreStylesheets(Document document, List<String> hrefs) {
    if (hrefs.isEmpty) return;
    final head = document.head;
    if (head == null) return;
    for (final href in hrefs.reversed) {
      // 用解析器造元素，属性键形式与解析出来的其它节点一致
      final nodes = html_parser
          .parseFragment('<link rel="stylesheet" type="text/css" href="${_escapeAttribute(href)}"/>')
          .nodes;
      if (nodes.isEmpty) continue;
      head.insertBefore(nodes.first, head.firstChild);
    }
  }
}

/// 属性键可能是 `String` 也可能是 `AttributeName`，统一取名字。
String _attributeName(Object key) => key is AttributeName ? key.name : '$key';

/// 脚本协议（含大小写与空白绕过写法）与内联 HTML 文档。
bool _isScriptUrl(String value) {
  // 属性值里可能夹着空白/控制字符来绕过朴素匹配，先归一化
  final normalized = value.replaceAll(RegExp(r'[\s\u0000-\u001F]'), '').toLowerCase();
  return normalized.startsWith('javascript:') ||
      normalized.startsWith('vbscript:') ||
      normalized.startsWith('data:text/html');
}

/// 属性值转义，避免 href 里的引号把标签拼断（防注入）。
String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
