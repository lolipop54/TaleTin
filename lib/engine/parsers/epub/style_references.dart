/// 从章节 HTML 里找出引用的样式文件（按出现顺序）。
List<String> linkedStyleSheets(String source) {
  const linkTag = r'<link\b[^>]*>';
  final relStyle = RegExp(
    r'''rel\s*=\s*["']?[^"'>]*stylesheet''',
    caseSensitive: false,
  );
  final hrefPattern = RegExp(
    r'''href\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  final result = <String>[];
  for (final match in RegExp(
    linkTag,
    caseSensitive: false,
  ).allMatches(source)) {
    final tag = match.group(0)!;
    if (!relStyle.hasMatch(tag)) continue;
    final href = hrefPattern.firstMatch(tag)?.group(1);
    if (href != null && href.trim().isNotEmpty) result.add(href.trim());
  }
  return result;
}

/// 章节内联的 `<style>` 内容，按出现顺序。
List<String> inlineStyleBlocks(String source) => [
  for (final match in RegExp(
    r'<style\b[^>]*>(.*?)</style>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(source))
    match.group(1)!,
];

/// 一节样式来源：外链文件或内联 `<style>`，顺序就是它们在 HTML 里出现的顺序。
class StyleTag {
  const StyleTag({required this.inline, required this.value});
  final bool inline;

  /// 外链是 href；内联是 CSS 文本。
  final String value;
}

/// 把 `<link rel=stylesheet>` 和 `<style>` 按真实出现位置交替列出。
///
/// 旧实现先把所有外链收完再收内联，遇到 `<style>…</style><link …>` 时
/// 覆盖顺序会反；CSS 层叠必须按文档顺序。
List<StyleTag> styleTagsInOrder(String source) {
  final pattern = RegExp(
    r'<link\b[^>]*>|<style\b[^>]*>(.*?)</style>',
    caseSensitive: false,
    dotAll: true,
  );
  final relStyle = RegExp(
    r'''rel\s*=\s*["']?[^"'>]*stylesheet''',
    caseSensitive: false,
  );
  final hrefPattern = RegExp(
    r'''href\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  final result = <StyleTag>[];
  for (final match in pattern.allMatches(source)) {
    final tag = match.group(0)!;
    if (tag.toLowerCase().startsWith('<link')) {
      if (!relStyle.hasMatch(tag)) continue;
      final href = hrefPattern.firstMatch(tag)?.group(1);
      if (href != null && href.trim().isNotEmpty) {
        result.add(StyleTag(inline: false, value: href.trim()));
      }
    } else {
      result.add(StyleTag(inline: true, value: match.group(1) ?? ''));
    }
  }
  return result;
}
