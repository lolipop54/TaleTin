/// 书籍样式表的最小解析：只认结构和对阅读有用的属性。
///
/// 设计原则：简化排版不是浏览器。这里只支持「标签／类名／ID／简单后代」这几种
/// 选择器，只认白名单里的属性，其余写法（伪类、@media、动画、浮动等）直接跳过。
/// 解析结果序列化成紧凑 JSON 存进书的正文目录，读章时随元数据交给转换器；
/// Rust 与 Dart 两个转换器使用完全相同的选择器匹配和属性归一化规则。
library;

/// 只保留白名单属性的解析结果。
class BookStyles {
  BookStyles(this.rules);

  /// 解析一个颜色写法（#rgb、#rrggbb、rgb()、常见英文名）。
  static int? parseColor(String? value) => _CssParser._color(value);

  /// 解析相对字号（em／rem／%／关键字）；px、pt 返回 null。
  static double? parseRelativeSize(String? value) =>
      _CssParser._fontSize(value);

  /// 解析文字装饰：0 无、1 下划线、2 删除线、3 两者都有。
  static int? parseDecoration(String? value) => _CssParser._decoration(value);

  /// 解析显式宽度／最大宽度，返回 `[数值(单位的 1/100), 单位]`。
  /// 单位：1 百分比、2 em、3 px。
  static List<int>? parseSize(String? value) => _CssParser._size(value);

  static final BookStyles none = BookStyles([]);

  final List<StyleRule> rules;

  bool get isEmpty => rules.isEmpty;

  Map<String, List<StyleRule>>? _indexCache;

  /// 按「最后一个复合条件的标签／类名／ID」建索引，避免每个元素遍历全部规则。
  Map<String, List<StyleRule>> get index {
    final cached = _indexCache;
    if (cached != null) return cached;
    final index = <String, List<StyleRule>>{};
    void add(String key, StyleRule rule) =>
        index.putIfAbsent(key, () => []).add(rule);
    for (final rule in rules) {
      if (rule.parts.isEmpty) continue;
      final last = rule.parts.last;
      var keyed = false;
      if (last.id != null) {
        add('i:${last.id}', rule);
        keyed = true;
      }
      if (last.tag != null) {
        add('t:${last.tag}', rule);
        keyed = true;
      }
      for (final name in last.classes) {
        add('c:$name', rule);
        keyed = true;
      }
      if (!keyed) add('u:*', rule);
    }
    return _indexCache = index;
  }

  /// 一个元素能命中的候选规则（已去重）。
  List<StyleRule> candidates(String tag, String? id, Set<String> classes) {
    final map = index;
    final result = <StyleRule>[];
    final seen = <StyleRule>{};
    void take(String key) {
      final list = map[key];
      if (list == null) return;
      for (final rule in list) {
        if (seen.add(rule)) result.add(rule);
      }
    }

    take('t:$tag');
    if (id != null) take('i:$id');
    for (final name in classes) {
      take('c:$name');
    }
    take('u:*');
    result.sort((a, b) {
      if (a.specificity != b.specificity) {
        return a.specificity.compareTo(b.specificity);
      }
      return a.order.compareTo(b.order);
    });
    return result;
  }

  /// 计算一个元素的最终声明（不含行内 style 覆盖）。
  StyleProps propsFor(
    String tag,
    String? id,
    Set<String> classes,
    List<ElementKey> ancestors,
  ) {
    var props = const StyleProps();
    for (final rule in candidates(tag, id, classes)) {
      if (!rule.matches(tag, id, classes, ancestors)) continue;
      props = rule.props.mergeOver(props);
    }
    return props;
  }

  /// 按顺序合并多份样式：后者覆盖前者，order 重新连续编号。
  static BookStyles combine(Iterable<BookStyles> sheets) {
    final rules = <StyleRule>[];
    var order = 0;
    for (final sheet in sheets) {
      for (final rule in sheet.rules) {
        rules.add(
          StyleRule(
            parts: rule.parts,
            child: rule.child,
            specificity: rule.specificity,
            order: order++,
            props: rule.props,
          ),
        );
      }
    }
    return BookStyles(rules);
  }

  /// 解析一本书的全部样式文件；顺序即层叠顺序（后出现的规则覆盖前面的）。
  static BookStyles parse(Map<String, String> files) {
    final parser = _CssParser();
    var order = 0;
    for (final css in files.values) {
      order = parser.parseSheet(css, order);
    }
    return BookStyles(parser.rules);
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'rules': [for (final rule in rules) rule.toJson()],
  };

  static BookStyles fromJson(Map<String, Object?> json) {
    final raw = json['rules'];
    if (raw is! List) return none;
    return BookStyles([
      for (final item in raw)
        if (item is Map) StyleRule.fromJson(item.cast<String, Object?>()),
    ]);
  }
}

/// 选择器里的一个复合条件：标签、类名、ID 的任意组合。
class SelectorPart {
  const SelectorPart({this.tag, this.id, this.classes = const []});

  final String? tag;
  final String? id;
  final List<String> classes;

  bool matches(
    String elementTag,
    String? elementId,
    Set<String> elementClasses,
  ) {
    if (tag != null && tag != elementTag) return false;
    if (id != null && id != elementId) return false;
    for (final name in classes) {
      if (!elementClasses.contains(name)) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    if (tag != null) 't': tag,
    if (id != null) 'i': id,
    if (classes.isNotEmpty) 'c': classes,
  };

  static SelectorPart fromJson(Map<String, Object?> json) => SelectorPart(
    tag: json['t'] as String?,
    id: json['i'] as String?,
    classes: [
      for (final value in (json['c'] as List? ?? const [])) value as String,
    ],
  );
}

/// 一条样式规则：选择器（从外到内）+ 组合符 + 归一化后的声明。
class StyleRule {
  const StyleRule({
    required this.parts,
    required this.child,
    required this.specificity,
    required this.order,
    required this.props,
  });

  /// 从祖先到自身的复合条件；最后一个是元素本身。
  final List<SelectorPart> parts;

  /// 第 i 个与第 i+1 个之间是否为子选择器（`>`），否则为后代选择器。
  final List<bool> child;
  final int specificity;
  final int order;
  final StyleProps props;

  bool matches(
    String tag,
    String? id,
    Set<String> classes,
    List<ElementKey> ancestors,
  ) {
    if (parts.isEmpty || !parts.last.matches(tag, id, classes)) return false;
    var depth = ancestors.length - 1;
    for (var i = parts.length - 2; i >= 0; i--) {
      final part = parts[i];
      if (child[i]) {
        if (depth < 0) return false;
        if (!part.matches(
          ancestors[depth].tag,
          ancestors[depth].id,
          ancestors[depth].classes,
        )) {
          return false;
        }
        depth--;
        continue;
      }
      var found = false;
      while (depth >= 0) {
        final ancestor = ancestors[depth];
        depth--;
        if (part.matches(ancestor.tag, ancestor.id, ancestor.classes)) {
          found = true;
          break;
        }
      }
      if (!found) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'sel': [for (final part in parts) part.toJson()],
    if (child.isNotEmpty) 'child': [for (final value in child) value ? 1 : 0],
    'spec': specificity,
    'order': order,
    'p': props.toJson(),
  };

  static StyleRule fromJson(Map<String, Object?> json) {
    final childRaw = json['child'] as List? ?? const [];
    return StyleRule(
      parts: [
        for (final item in (json['sel'] as List? ?? const []))
          SelectorPart.fromJson((item as Map).cast<String, Object?>()),
      ],
      child: [for (final value in childRaw) (value as num).toInt() != 0],
      specificity: (json['spec'] as num?)?.toInt() ?? 0,
      order: (json['order'] as num?)?.toInt() ?? 0,
      props: StyleProps.fromJson(
        (json['p'] as Map? ?? const {}).cast<String, Object?>(),
      ),
    );
  }
}

/// 元素在选择器匹配时用到的身份（用于后代匹配）。
class ElementKey {
  const ElementKey(this.tag, this.id, this.classes);

  final String tag;
  final String? id;
  final Set<String> classes;
}

/// 白名单里的块级／行内属性。
///
/// 数值约定：长度一律用「十分之一 em」的整数保存，颜色用 ARGB 整数；
/// 字号用相对倍数。null／0 表示“这本书没有指定”。
class StyleProps {
  const StyleProps({
    this.align,
    this.indent,
    this.weight,
    this.italic,
    this.size,
    this.color,
    this.background,
    this.borders = const {},
    this.radius = const [],
    this.shadow,
    this.padding = const [],
    this.margins = const [],
    this.listStyle,
    this.whiteSpacePre = false,
    this.textShadow,
    this.decoration,
    this.letterSpacing,
    this.wordSpacing,
    this.width,
    this.maxWidth,
  });

  /// 1 左、2 居中、3 右、4 两端对齐
  final int? align;

  /// 0 明确取消首行缩进，1 有首行缩进
  final int? indent;

  /// 1 加粗、2 正常
  final int? weight;

  /// 1 斜体、2 正常
  final int? italic;

  /// 相对字号倍数（1 表示不变）
  final double? size;

  final int? color;
  final int? background;

  /// 边框：key 为 `t`／`r`／`b`／`l`，值 `[宽度(0.01em), 样式, 颜色]`
  final Map<String, List<int>> borders;

  /// 圆角四个值（0.01em，顺序 左上 右上 右下 左下）
  final List<int> radius;

  /// 阴影 `[x, y, 模糊, 颜色]`（0.01em）
  final List<int>? shadow;

  /// 内边距 `[上, 右, 下, 左]`（0.01em）
  final List<int> padding;

  /// 四边外边距，顺序上、右、下、左，单位百分之一 em（与 padding 同一口径）。
  /// 这一版只把上、下用在块流间距上；左外边距仍按历史做法折进左内边距。
  final List<int> margins;

  /// 0 无标记、1 数字、2 小写字母
  final int? listStyle;

  /// `white-space: pre`：保留换行与空格
  final bool whiteSpacePre;

  /// 文字阴影 `[x, y, 模糊, 颜色]`（0.01em）
  final List<int>? textShadow;

  /// 文字装饰：0 无、1 下划线、2 删除线、3 两者都有；null 表示这本书没写
  final int? decoration;

  /// 字距（`letter-spacing`），单位百分之一 em，可以为负；null 表示书里没写。
  final int? letterSpacing;

  /// 词距（`word-spacing`），单位百分之一 em，可以为负；null 表示书里没写。
  final int? wordSpacing;

  /// 显式宽度／最大宽度 `[数值, 单位]`，数值是单位的 1/100。
  /// 单位：1 百分比、2 em、3 px。目前只有图片使用。
  final List<int>? width;
  final List<int>? maxWidth;

  bool get isEmpty =>
      align == null &&
      indent == null &&
      weight == null &&
      italic == null &&
      size == null &&
      color == null &&
      background == null &&
      borders.isEmpty &&
      radius.isEmpty &&
      shadow == null &&
      padding.isEmpty &&
      margins.isEmpty &&
      listStyle == null &&
      !whiteSpacePre &&
      textShadow == null &&
      decoration == null &&
      letterSpacing == null &&
      wordSpacing == null &&
      width == null &&
      maxWidth == null;

  /// 把另一条（优先级更低的）声明合并到后面：this 覆盖 base。
  StyleProps mergeOver(StyleProps base) => StyleProps(
    align: align ?? base.align,
    indent: indent ?? base.indent,
    weight: weight ?? base.weight,
    italic: italic ?? base.italic,
    size: size ?? base.size,
    color: color ?? base.color,
    background: background ?? base.background,
    borders: borders.isEmpty ? base.borders : {...base.borders, ...borders},
    radius: radius.isEmpty ? base.radius : radius,
    shadow: shadow ?? base.shadow,
    padding: padding.isEmpty ? base.padding : padding,
    margins: margins.isEmpty ? base.margins : margins,
    listStyle: listStyle ?? base.listStyle,
    whiteSpacePre: whiteSpacePre || base.whiteSpacePre,
    textShadow: textShadow ?? base.textShadow,
    decoration: decoration ?? base.decoration,
    letterSpacing: letterSpacing ?? base.letterSpacing,
    wordSpacing: wordSpacing ?? base.wordSpacing,
    width: width ?? base.width,
    maxWidth: maxWidth ?? base.maxWidth,
  );

  Map<String, Object?> toJson() => {
    if (align != null) 'a': align,
    if (indent != null) 'ind': indent,
    if (weight != null) 'w': weight,
    if (italic != null) 'i': italic,
    if (size != null) 'fs': size,
    if (color != null) 'c': color,
    if (background != null) 'bg': background,
    if (borders.isNotEmpty) 'bo': borders,
    if (radius.isNotEmpty) 'rad': radius,
    if (shadow != null) 'sh': shadow,
    if (padding.isNotEmpty) 'pad': padding,
    if (margins.isNotEmpty) 'mg': margins,
    if (listStyle != null) 'ls': listStyle,
    if (whiteSpacePre) 'pre': true,
    if (textShadow != null) 'tsh': textShadow,
    if (decoration != null) 'dec': decoration,
    if (letterSpacing != null) 'lsp': letterSpacing,
    if (wordSpacing != null) 'wsp': wordSpacing,
    if (width != null) 'wid': width,
    if (maxWidth != null) 'mw': maxWidth,
  };

  static StyleProps fromJson(Map<String, Object?> json) {
    List<int> ints(Object? raw) => [
      for (final value in (raw as List? ?? const [])) (value as num).toInt(),
    ];
    return StyleProps(
      align: (json['a'] as num?)?.toInt(),
      indent: (json['ind'] as num?)?.toInt(),
      weight: (json['w'] as num?)?.toInt(),
      italic: (json['i'] as num?)?.toInt(),
      size: (json['fs'] as num?)?.toDouble(),
      color: (json['c'] as num?)?.toInt(),
      background: (json['bg'] as num?)?.toInt(),
      borders: {
        for (final entry in (json['bo'] as Map? ?? const {}).entries)
          entry.key as String: ints(entry.value),
      },
      radius: ints(json['rad']),
      shadow: json['sh'] == null ? null : ints(json['sh']),
      padding: ints(json['pad']),
      margins: ints(json['mg']),
      listStyle: (json['ls'] as num?)?.toInt(),
      whiteSpacePre: json['pre'] == true,
      textShadow: json['tsh'] == null ? null : ints(json['tsh']),
      decoration: (json['dec'] as num?)?.toInt(),
      letterSpacing: (json['lsp'] as num?)?.toInt(),
      wordSpacing: (json['wsp'] as num?)?.toInt(),
      width: json['wid'] == null ? null : ints(json['wid']),
      maxWidth: json['mw'] == null ? null : ints(json['mw']),
    );
  }
}

/// 简单的 CSS 扫描器：只处理规则块，跳过 @ 规则和注释。
class _CssParser {
  final List<StyleRule> rules = [];
  var _order = 0;

  /// 样式表里定义的 CSS 变量（`--x: value`），供 `var(--x)` 替换。
  static final _varUse = RegExp(
    r'var\(\s*(--[A-Za-z0-9_-]+)\s*(?:,\s*([^()]*))?\)',
  );

  static final _comment = RegExp(r'/\*.*?\*/', dotAll: true);

  int parseSheet(String css, int order) {
    _order = order;
    // 注释里常带分号和花括号，必须先去掉，否则扫描会错位
    final text = css.replaceAll(_comment, ' ');
    css = text;
    var i = 0;
    final length = css.length;
    while (i < length) {
      // 跳到下一个选择器或 @ 规则
      while (i < length && _isSpace(css.codeUnitAt(i))) {
        i++;
      }
      if (i >= length) break;
      final start = i;
      var depth = 0;
      while (i < length) {
        final code = css.codeUnitAt(i);
        if (code == 0x7B || code == 0x7D || code == 0x3B) break;
        if (code == 0x28) depth++;
        if (code == 0x29 && depth > 0) depth--;
        i++;
      }
      if (i >= length) break;
      final head = css.substring(start, i).trim();
      if (css.codeUnitAt(i) == 0x3B) {
        // @charset／@import 之类
        i++;
        continue;
      }
      if (css.codeUnitAt(i) == 0x7D) {
        i++;
        continue;
      }
      // 读取 {...}，支持嵌套一层（@media 之类直接跳过内容）
      final bodyStart = i + 1;
      var braces = 1;
      i++;
      while (i < length && braces > 0) {
        final code = css.codeUnitAt(i);
        if (code == 0x7B) braces++;
        if (code == 0x7D) braces--;
        i++;
      }
      final body = css.substring(bodyStart, i - 1);
      if (head.startsWith('@')) continue;
      _pending.add((head, body));
    }
    // 先收集 CSS 变量，再逐条归一化（变量可能定义在后面的规则里）
    for (final (_, body) in _pending) {
      for (final entry in _parseDeclarations(body).entries) {
        if (entry.key.startsWith('--')) {
          _vars[entry.key] = _substitute(entry.value);
        }
      }
    }
    for (final (selectorText, body) in _pending) {
      _addRule(selectorText, body);
    }
    _pending.clear();
    return _order;
  }

  final _pending = <(String, String)>[];
  final _vars = <String, String>{};

  /// 把 `var(--x, fallback)` 换成实际值。
  String _substitute(String value) {
    if (!value.contains('var(')) return value;
    var result = value;
    for (var i = 0; i < 8 && result.contains('var('); i++) {
      final next = result.replaceAllMapped(_varUse, (match) {
        final name = match.group(1)!;
        final fallback = match.group(2)?.trim();
        final defined = _vars[name];
        if (defined != null) return defined;
        return fallback ?? '';
      });
      if (next == result) break;
      result = next;
    }
    return result;
  }

  void _addRule(String selectorText, String body) {
    final declarations = _parseDeclarations(body);
    if (declarations.isEmpty) return;
    final props = _normalize(declarations);
    if (props.isEmpty) return;
    for (final selector in selectorText.split(',')) {
      final parsed = _parseSelector(selector.trim());
      if (parsed == null) continue;
      rules.add(
        StyleRule(
          parts: parsed.$1,
          child: parsed.$2,
          specificity: parsed.$3,
          order: _order++,
          props: props,
        ),
      );
    }
  }

  static bool _isSpace(int code) =>
      code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

  /// 解析单条选择器；含伪类、属性选择器等不支持的写法时返回 null。
  (List<SelectorPart>, List<bool>, int)? _parseSelector(String selector) {
    if (selector.isEmpty) return null;
    final parts = <SelectorPart>[];
    final child = <bool>[];
    var i = 0;
    var pendingChild = false;
    var first = true;
    final length = selector.length;
    while (i < length) {
      final code = selector.codeUnitAt(i);
      if (_isSpace(code)) {
        i++;
        pendingChild = false;
        continue;
      }
      if (code == 0x3E) {
        // >
        i++;
        pendingChild = true;
        continue;
      }
      if (code == 0x2B || code == 0x7E) {
        // + 与 ~ 兄弟选择器：不支持
        return null;
      }
      // 读取一个复合选择器：标签／.class／#id
      final start = i;
      var tag = '';
      while (i < length) {
        final c = selector.codeUnitAt(i);
        if (c == 0x2E || c == 0x23) break; // . 或 #
        if (_isSpace(c) || c == 0x3E) break;
        tag += selector[i];
        i++;
      }
      final classes = <String>[];
      String? id;
      while (i < length) {
        final c = selector.codeUnitAt(i);
        if (c == 0x2E) {
          i++;
          final s = i;
          while (i < length && _isNameChar(selector.codeUnitAt(i))) {
            i++;
          }
          if (i == s) return null;
          classes.add(selector.substring(s, i));
          continue;
        }
        if (c == 0x23) {
          i++;
          final s = i;
          while (i < length && _isNameChar(selector.codeUnitAt(i))) {
            i++;
          }
          if (i == s) return null;
          id = selector.substring(s, i);
          continue;
        }
        break;
      }
      if (i == start) return null;
      // 不支持 : 伪类、[ ] 属性、* 通配里的特殊写法
      if (i < length && selector.codeUnitAt(i) == 0x3A) return null;
      if (i < length &&
          (selector.codeUnitAt(i) == 0x5B || selector.codeUnitAt(i) == 0x28)) {
        return null;
      }
      final tagName = tag.toLowerCase();
      if (tagName.isNotEmpty &&
          !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(tagName)) {
        return null;
      }
      if (!first) child.add(pendingChild);
      parts.add(
        SelectorPart(
          tag: tagName.isEmpty ? null : tagName,
          id: id,
          classes: classes,
        ),
      );
      first = false;
      pendingChild = false;
    }
    if (parts.isEmpty) return null;
    if (child.length != parts.length - 1) return null;
    var specificity = 0;
    for (final part in parts) {
      if (part.id != null) specificity += 10000;
      specificity += part.classes.length * 100;
      if (part.tag != null) specificity += 1;
    }
    return (parts, child, specificity);
  }

  static bool _isNameChar(int code) =>
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      code == 0x2D ||
      code == 0x5F;

  /// 解析一个声明块，返回原始声明（后出现的覆盖前面的）。
  Map<String, String> _parseDeclarations(String body) {
    final result = <String, String>{};
    var depth = 0;
    var start = 0;
    for (var i = 0; i <= body.length; i++) {
      if (i == body.length) {
        _addDeclaration(body.substring(start), result, depth);
        break;
      }
      final code = body.codeUnitAt(i);
      if (code == 0x28) depth++;
      if (code == 0x29 && depth > 0) depth--;
      if (code == 0x3B && depth == 0) {
        _addDeclaration(body.substring(start, i), result, depth);
        start = i + 1;
      }
    }
    return result;
  }

  void _addDeclaration(String text, Map<String, String> out, int depth) {
    if (depth != 0) return;
    final colon = text.indexOf(':');
    if (colon <= 0) return;
    final key = text.substring(0, colon).trim().toLowerCase();
    var value = text.substring(colon + 1).trim();
    value = _substitute(value)
        .replaceAll(RegExp(r'\s*!important\s*$', caseSensitive: false), '');
    if (key.isEmpty || value.isEmpty) return;
    if (key.startsWith('--')) {
      out[key] = value;
      return;
    }
    if (!_whitelist.contains(key) && !_borderShorthands.contains(key)) return;
    out[key] = value;
  }

  static const _whitelist = {
    'text-align',
    'text-indent',
    'font-weight',
    'font-style',
    'font-size',
    'color',
    'background',
    'background-color',
    'border',
    'border-top',
    'border-right',
    'border-bottom',
    'border-left',
    'border-color',
    'border-width',
    'border-style',
    'border-top-width',
    'border-right-width',
    'border-bottom-width',
    'border-left-width',
    'border-top-style',
    'border-right-style',
    'border-bottom-style',
    'border-left-style',
    'border-top-color',
    'border-right-color',
    'border-bottom-color',
    'border-left-color',
    'border-radius',
    'box-shadow',
    'padding',
    'padding-top',
    'padding-right',
    'padding-bottom',
    'padding-left',
    'margin',
    'margin-top',
    'margin-right',
    'margin-bottom',
    'margin-left',
    'list-style-type',
    'list-style',
    'white-space',
    'text-shadow',
    'letter-spacing',
    'word-spacing',
    'text-decoration',
    'width',
    'max-width',
    'duokan-text-indent',
  };

  static const _borderShorthands = {
    'border',
    'border-top',
    'border-right',
    'border-bottom',
    'border-left',
  };

  /// 把原始声明归一化成白名单字段。
  StyleProps _normalize(Map<String, String> css) {
    var align = _align(css['text-align']);
    // 多看阅读的私有属性等同于 text-indent
    final indent = _indent(css['text-indent'] ?? css['duokan-text-indent']);
    final weight = _weight(css['font-weight']);
    final italic = _italic(css['font-style']);
    final size = _fontSize(css['font-size']);
    final color = _color(css['color']);
    var background = _color(css['background-color']);
    background ??= _colorFromBackground(css['background']);
    final borders = _borders(css);
    final radius = _radius(css['border-radius']);
    final shadow = _shadow(css['box-shadow']);
    final padding = _padding(css);
    final margins = _margins(css);
    final marginLeft = _length(css['margin-left']);
    // `list-style: none` 这类简写同样要认，否则目录列表会多出手册外的圆点
    final listStyle =
        _listStyle(css['list-style-type']) ??
        _listStyleFromShorthand(css['list-style']);
    final whiteSpacePre = (css['white-space'] ?? '').toLowerCase().startsWith(
      'pre',
    );
    final textShadow = _shadow(css['text-shadow']);
    final decoration = _decoration(css['text-decoration']);
    // 字距／词距：和 padding 一样折算成百分之一 em，负值（紧缩）保留；normal 等于 0。
    final letterSpacing = _spacing(css['letter-spacing']);
    final wordSpacing = _spacing(css['word-spacing']);
    final width = _size(css['width']);
    final maxWidth = _size(css['max-width']);
    var pad = padding;
    if (marginLeft != null && marginLeft > 0) {
      if (pad.length == 4) {
        pad = [pad[0], pad[1], pad[2], pad[3] + marginLeft];
      }
    }
    if (align == 1) align = null; // 左对齐是默认值，不必存
    return StyleProps(
      align: align,
      indent: indent,
      weight: weight,
      italic: italic,
      size: size,
      color: color,
      background: background,
      borders: borders,
      radius: radius,
      shadow: shadow,
      padding: pad,
      margins: margins,
      listStyle: listStyle,
      whiteSpacePre: whiteSpacePre,
      textShadow: textShadow,
      decoration: decoration,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      width: width,
      maxWidth: maxWidth,
    );
  }

  static int? _align(String? value) => switch ((value ?? '').toLowerCase()) {
    'left' || 'start' => 1,
    'center' => 2,
    'right' || 'end' => 3,
    'justify' => 4,
    _ => null,
  };

  static int? _indent(String? value) {
    final length = _length(value);
    if (length == null) return null;
    return length > 0 ? 1 : 0;
  }

  static int? _weight(String? value) {
    final text = (value ?? '').toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'bold' || text == 'bolder') return 1;
    if (text == 'normal' || text == 'lighter') return 2;
    final numeric = int.tryParse(text);
    if (numeric == null) return null;
    return numeric >= 600 ? 1 : 2;
  }

  static int? _italic(String? value) {
    final text = (value ?? '').toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'italic' || text == 'oblique') return 1;
    if (text == 'normal') return 2;
    return null;
  }

  /// 只接受相对单位：px／pt 这类写死的大小交给阅读设置。
  static double? _fontSize(String? value) {
    final text = (value ?? '').toLowerCase().trim();
    if (text.isEmpty) return null;
    const keywords = {
      'xx-small': 0.6,
      'x-small': 0.75,
      'small': 0.85,
      'medium': 1.0,
      'large': 1.2,
      'x-large': 1.4,
      'xx-large': 1.6,
      'smaller': 0.85,
      'larger': 1.2,
    };
    final keyword = keywords[text];
    if (keyword != null) return keyword;
    final match = RegExp(r'^([0-9.]+)\s*(em|rem|%)$').firstMatch(text);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null || number <= 0) return null;
    final factor = match.group(2) == '%' ? number / 100 : number;
    return factor.clamp(0.5, 2.2);
  }

  static int? _color(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'transparent' || text == 'inherit' || text == 'initial') {
      return null;
    }
    return _parseColor(text);
  }

  static int? _colorFromBackground(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    for (final token in text.split(RegExp(r'\s+'))) {
      final color = _parseColor(token);
      if (color != null) return color;
    }
    return null;
  }

  static const _namedColors = {
    'black': 0xFF000000,
    'white': 0xFFFFFFFF,
    'red': 0xFFFF0000,
    'green': 0xFF008000,
    'blue': 0xFF0000FF,
    'gray': 0xFF808080,
    'grey': 0xFF808080,
    'silver': 0xFFC0C0C0,
    'yellow': 0xFFFFFF00,
    'orange': 0xFFFFA500,
    'purple': 0xFF800080,
    'pink': 0xFFFFC0CB,
    'brown': 0xFFA52A2A,
    'navy': 0xFF000080,
    'teal': 0xFF008080,
    'olive': 0xFF808000,
    'maroon': 0xFF800000,
    'lime': 0xFF00FF00,
    'aqua': 0xFF00FFFF,
    'cyan': 0xFF00FFFF,
    'magenta': 0xFFFF00FF,
    'fuchsia': 0xFFFF00FF,
    'darkgray': 0xFFA9A9A9,
    'darkgrey': 0xFFA9A9A9,
    'lightgray': 0xFFD3D3D3,
    'lightgrey': 0xFFD3D3D3,
    'whitesmoke': 0xFFF5F5F5,
    'gainsboro': 0xFFDCDCDC,
  };

  static int? _parseColor(String text) {
    if (text.startsWith('#')) {
      final hex = text.substring(1);
      if (hex.length == 3) {
        final r = int.tryParse(hex[0] * 2, radix: 16);
        final g = int.tryParse(hex[1] * 2, radix: 16);
        final b = int.tryParse(hex[2] * 2, radix: 16);
        if (r == null || g == null || b == null) return null;
        return 0xFF000000 | (r << 16) | (g << 8) | b;
      }
      if (hex.length == 6) {
        final value = int.tryParse(hex, radix: 16);
        return value == null ? null : 0xFF000000 | value;
      }
      if (hex.length == 8) {
        final value = int.tryParse(hex, radix: 16);
        return value;
      }
      return null;
    }
    final rgb = RegExp(
      r'^rgba?\(([0-9.]+)[,\s]+([0-9.]+)[,\s]+([0-9.]+)(?:[,\s/]+([0-9.]+%?))?\)$',
    ).firstMatch(text);
    if (rgb != null) {
      final r = double.tryParse(rgb.group(1)!)?.round().clamp(0, 255);
      final g = double.tryParse(rgb.group(2)!)?.round().clamp(0, 255);
      final b = double.tryParse(rgb.group(3)!)?.round().clamp(0, 255);
      if (r == null || g == null || b == null) return null;
      var alpha = 255;
      final rawAlpha = rgb.group(4);
      if (rawAlpha != null) {
        final value = double.tryParse(rawAlpha.replaceAll('%', ''));
        if (value != null) {
          alpha = rawAlpha.endsWith('%')
              ? (value / 100 * 255).round().clamp(0, 255)
              : (value * 255).round().clamp(0, 255);
        }
      }
      return (alpha << 24) | (r << 16) | (g << 8) | b;
    }
    return _namedColors[text];
  }

  /// 长度换算成「百分之一 em」。px 按 16px=1em，pt 按 12pt=1em。
  /// 四边外边距：`margin` 简写（1～4 个值）与四条长写属性，单位换算与 padding 同一口径。
  ///
  /// 只写某一条时，其余边按 0 处理（CSS 初始值就是 0）；`auto` 不参与块流间距。
  /// 左外边距另外还会被折进左内边距（历史做法），这里的值不参与水平缩进，避免重复。
  static List<int> _margins(Map<String, String> css) {
    final sides = List<int?>.filled(4, null);
    final shorthand = css['margin'];
    if (shorthand != null) {
      final parts = shorthand
          .trim()
          .split(RegExp(r'\s+'))
          .where((part) => part.isNotEmpty)
          .toList();
      final values = [for (final part in parts.take(4)) _marginLength(part)];
      if (values.isNotEmpty && values.every((value) => value != null)) {
        switch (values.length) {
          case 1:
            sides.fillRange(0, 4, values[0]);
          case 2:
            sides[0] = values[0];
            sides[1] = values[1];
            sides[2] = values[0];
            sides[3] = values[1];
          case 3:
            sides[0] = values[0];
            sides[1] = values[1];
            sides[2] = values[2];
            sides[3] = values[1];
          default:
            sides[0] = values[0];
            sides[1] = values[1];
            sides[2] = values[2];
            sides[3] = values[3];
        }
      }
    }
    const names = [
      'margin-top',
      'margin-right',
      'margin-bottom',
      'margin-left',
    ];
    for (var i = 0; i < 4; i++) {
      final value = _marginLength(css[names[i]]);
      if (value != null) sides[i] = value;
    }
    if (sides.every((value) => value == null)) return const [];
    return [for (final value in sides) value ?? 0];
  }

  static int? _marginLength(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty || text == 'auto') return null;
    return _length(text);
  }

  /// 字距／词距：`normal` 明确表示 0；其它按长度换算（与 padding 同一口径）。
  static int? _spacing(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'normal') return 0;
    return _length(text);
  }

  static int? _length(String? value) {
    final text = (value ?? '').toLowerCase().trim();
    if (text.isEmpty) return null;
    if (text == '0') return 0;
    final match = RegExp(r'^(-?[0-9.]+)\s*(em|rem|px|pt)?$').firstMatch(text);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null) return null;
    final unit = match.group(2) ?? '';
    final em = switch (unit) {
      'px' => number / 16,
      'pt' => number / 12,
      _ => number,
    };
    return (em * 100).round();
  }

  static List<int> _lengths(String? value, int count) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return const [];
    final values = <int>[];
    for (final token in text.split(RegExp(r'\s+'))) {
      final length = _length(token);
      if (length != null) values.add(length);
    }
    if (values.isEmpty) return const [];
    if (values.length == 1) return List.filled(count, values.first);
    if (values.length == 2) {
      return [values[0], values[1], values[0], values[1]];
    }
    if (values.length == 3) {
      return [values[0], values[1], values[2], values[1]];
    }
    return values.take(4).toList();
  }

  static List<int> _radius(String? value) => _lengths(value, 4);

  static List<int> _padding(Map<String, String> css) {
    final all = css['padding'];
    var result = _lengths(all, 4);
    final hasSides = const [
      'padding-top',
      'padding-right',
      'padding-bottom',
      'padding-left',
    ].any((key) => css.containsKey(key));
    if (result.isEmpty && !hasSides) return const [];
    if (result.isEmpty) result = const [0, 0, 0, 0];
    final copy = List<int>.of(result, growable: true);
    for (final entry in {
      'padding-top': 0,
      'padding-right': 1,
      'padding-bottom': 2,
      'padding-left': 3,
    }.entries) {
      final value = _length(css[entry.key]);
      if (value != null) copy[entry.value] = value;
    }
    return copy;
  }

  /// 解析 `border` 简写和单边写法。
  ///
  /// 值格式：`[宽度(0.01em), 样式(1 实线/2 虚线/3 点线), 颜色]`。
  /// `border-width/style/color` 可以写 1～4 个值，按 CSS 规则分配到四边
  /// （上、右、下、左）；`border-left-width` 这类单边分量单独覆盖。
  Map<String, List<int>> _borders(Map<String, String> css) {
    const sides = ['t', 'r', 'b', 'l'];
    final result = <String, List<int>>{};

    /// 1～4 个值展开成四边。
    List<String> expand(String? value) {
      final parts = (value ?? '').trim().split(RegExp(r'\s+'))
        ..removeWhere((part) => part.isEmpty);
      if (parts.isEmpty) return const ['', '', '', ''];
      return switch (parts.length) {
        1 => [parts[0], parts[0], parts[0], parts[0]],
        2 => [parts[0], parts[1], parts[0], parts[1]],
        3 => [parts[0], parts[1], parts[2], parts[1]],
        _ => [parts[0], parts[1], parts[2], parts[3]],
      };
    }

    final all = css['border'];
    if (all != null && all.trim().isNotEmpty) {
      final parsed = _borderValue(all);
      for (final side in sides) {
        result[side] = parsed ?? const [0, 0, 0];
      }
    }
    final widths = expand(css['border-width']);
    final styles = expand(css['border-style']);
    final colors = expand(css['border-color']);
    for (var i = 0; i < sides.length; i++) {
      final side = sides[i];
      final width = _length(widths[i]);
      final style = _borderStyle(styles[i]);
      final color = _color(colors[i]);
      if (width == null && style == null && color == null) continue;
      final base = result[side] ?? const [0, 0, 0];
      result[side] = [
        width ?? base[0],
        style ?? base[1],
        color ?? (base[2] != 0 ? base[2] : 0xFF999999),
      ];
    }
    // 单边简写：`border-left: 2px solid #ccc`
    for (final entry in const {
      'top': 't',
      'right': 'r',
      'bottom': 'b',
      'left': 'l',
    }.entries) {
      final value = css['border-${entry.key}'];
      if (value == null || value.trim().isEmpty) continue;
      result[entry.value] = _borderValue(value) ?? const [0, 0, 0];
    }
    // 单边分量：`border-left-width: 0.2em`
    for (final entry in const {
      'top': 't',
      'right': 'r',
      'bottom': 'b',
      'left': 'l',
    }.entries) {
      final base = result[entry.value] ?? const [0, 0, 0];
      final width = _length(css['border-${entry.key}-width']);
      final style = _borderStyle(css['border-${entry.key}-style']);
      final color = _color(css['border-${entry.key}-color']);
      if (width == null && style == null && color == null) continue;
      result[entry.value] = [
        width ?? base[0],
        style ?? base[1],
        color ?? (base[2] != 0 ? base[2] : 0xFF999999),
      ];
    }
    result.removeWhere((_, value) => value[0] <= 0 || value[1] == 0);
    return result;
  }

  static List<int>? _borderValue(String value) {
    final text = value.trim().toLowerCase();
    if (text.isEmpty || text == 'none' || text == '0') return null;
    // 默认 1px ≈ 0.0625em
    var width = 6;
    var style = 1;
    int? color;
    for (final token in text.split(RegExp(r'\s+'))) {
      final parsedColor = _parseColor(token);
      if (parsedColor != null) {
        color = parsedColor;
        continue;
      }
      final parsedStyle = _borderStyle(token);
      if (parsedStyle != null) {
        style = parsedStyle;
        continue;
      }
      final length = _length(token);
      if (length != null) width = length;
    }
    if (style == 0) return null;
    return [width <= 0 ? 1 : width, style, color ?? 0xFF999999];
  }

  static int? _borderStyle(String? value) => switch ((value ?? '').trim()) {
    'none' || 'hidden' => 0,
    'solid' => 1,
    'dashed' => 2,
    'dotted' => 3,
    'double' => 1,
    _ => null,
  };

  /// 只取第一层阴影：`[x, y, 模糊, 颜色]`（0.1em）。
  static List<int>? _shadow(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty || text == 'none') return null;
    if (text.contains('inset')) return null;
    // 去掉逗号分隔的多层阴影，只留第一层
    final first = text.split(',').first;
    final lengths = <int>[];
    int? color;
    for (final token in first.split(RegExp(r'\s+'))) {
      final parsedColor = _parseColor(token);
      if (parsedColor != null) {
        color = parsedColor;
        continue;
      }
      final parsedLength = _length(token);
      if (parsedLength != null) lengths.add(parsedLength);
    }
    if (lengths.length < 2) return null;
    return [
      lengths[0],
      lengths[1],
      lengths.length >= 3 ? lengths[2] : 0,
      color ?? 0x55000000,
    ];
  }

  /// 列表标记类型编码：
  /// 0 无、1 数字、2 小写字母、3 大写字母、4 小写罗马数字、5 大写罗马数字、
  /// 6 圆点、7 空心圆、8 方块。
  static int? _listStyle(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'none') return 0;
    if (text == 'decimal' || text == 'decimal-leading-zero') return 1;
    if (text.startsWith('lower-alpha') || text.startsWith('lower-latin')) {
      return 2;
    }
    if (text.startsWith('upper-alpha') || text.startsWith('upper-latin')) {
      return 3;
    }
    if (text.startsWith('lower-roman')) return 4;
    if (text.startsWith('upper-roman')) return 5;
    if (text.startsWith('disc')) return 6;
    if (text.startsWith('circle')) return 7;
    if (text.startsWith('square')) return 8;
    return null;
  }

  /// `list-style: none`、`list-style: circle inside` 这类简写里取出标记类型。
  /// `inside`／`outside` 只影响标记位置，本项目标记始终画在文字左侧，忽略。
  static int? _listStyleFromShorthand(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty || text.contains('url(')) return null;
    for (final token in text.split(RegExp(r'\s+'))) {
      final style = _listStyle(token);
      if (style != null) return style;
    }
    return null;
  }

  /// `text-decoration`：0 无、1 下划线、2 删除线、3 两者都有。
  static int? _decoration(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    var bits = 0;
    for (final token in text.split(RegExp(r'\s+'))) {
      if (token == 'none') return 0;
      if (token.startsWith('underline')) bits |= 1;
      if (token.startsWith('line-through')) bits |= 2;
    }
    return bits == 0 ? null : bits;
  }

  /// 显式宽度／最大宽度：只认 `%`、`em`、`rem`、`px`，`auto` 与其它写法忽略。
  /// 返回 `[数值(单位的 1/100), 单位]`，单位 1 百分比、2 em、3 px。
  static List<int>? _size(String? value) {
    final text = (value ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    final match = RegExp(r'^([0-9.]+)\s*(%|em|rem|px)$').firstMatch(text);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null || number < 0) return null;
    final unit = switch (match.group(2)) {
      '%' => 1,
      'em' || 'rem' => 2,
      _ => 3,
    };
    return [(number * 100).round(), unit];
  }
}
