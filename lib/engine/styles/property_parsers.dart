/// 把 CSS 的具体写法（`1.5em`、`#c00`、`small`）解析成带单位的样式值。
///
/// 这一层只做「一个属性值 → 一个类型化值」，不做三件事：
/// 1. 不乘成像素（那要看当前字号和纸面宽度，是排版上下文的事）；
/// 2. 不做层叠和继承（谁是最终值由样式解析器决定）；
/// 3. 不认识 `inherit`／`initial`／`unset`：这三个关键字作用于整个声明，
///    由层叠阶段处理，到了这里统一返回 null（表示「这条声明不产生具体值」）。
///
/// 和旧解析器的关系：旧的 `BookStyles` 白名单还留在生产路径上，这里的新实现
/// 由 `test/engine/style_parser_parity_test.dart` 与旧实现逐项对照，等 P3 切换时
/// 直接删掉旧的那一份，不会出现「两套各算各的」。
library;

import 'style_box_value.dart';
import 'style_value.dart';

/// 边框没写颜色时的默认色。
///
/// 这是引擎历史行为（灰线），不是 CSS 的 `currentColor`；迁移期必须保持一致，
/// 否则所有只写 `border: 1px solid` 的书会突然变成文字色。
const ColorValue kDefaultBorderColor = ColorValue(0xFF999999);

/// 阴影没写颜色时的默认色（半透明黑）。
const ColorValue kDefaultShadowColor = ColorValue(0x55000000);

/// 字号关键字的倍数。
///
/// 数值沿用引擎历史实现（`small` = 0.85、大字号 1.2／1.4／1.6），
/// 不照抄浏览器的 16px 绝对表：我们的正文基准是用户字号，关键字只能是相对倍数。
const Map<String, double> _fontSizeKeywords = {
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

/// 相对字号的安全范围：书里写 `0.1em` 或 `5em` 会把标题撑坏。
const double _minFontFactor = 0.5;
const double _maxFontFactor = 2.2;

/// 具名颜色。只收常见的一批；CSS 的 148 个名字用完再补，不猜。
const Map<String, int> _namedColors = {
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

abstract final class StyleParser {
  /// 解析长度：`em`／`rem`／`%`／`px`／`pt`，以及 `auto`。
  ///
  /// 不带单位的数字：`0` 当 0；其它按 em 处理——CSS 规范不允许，但样书里确实
  /// 有人写 `margin: 1`，按 1em 读比整条丢掉更符合作者的意图。
  static Length? length(String? raw, {bool allowAuto = false}) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    if (text == 'auto') return allowAuto ? const AutoLength() : null;
    if (text == '0') return const PxLength(0);
    final quantity = _quantity(text);
    if (quantity == null) return null;
    return switch (quantity.unit) {
      'em' => EmLength(quantity.value),
      'rem' => RemLength(quantity.value),
      '%' => PercentLength(quantity.value / 100),
      'px' => PxLength(quantity.value),
      'pt' => PtLength(quantity.value),
      _ => EmLength(quantity.value),
    };
  }

  /// 四边长度（`margin`／`padding` 简写）。
  static Edges? edges(String? raw, {bool allowAuto = false}) {
    final sides = sideLengths(raw, allowAuto: allowAuto);
    if (sides == null) return null;
    return Edges(
      top: sides[0],
      right: sides[1],
      bottom: sides[2],
      left: sides[3],
    );
  }

  /// 把 `1`～`4` 个值展开成上右下左四边；空或非法返回 null。
  static List<Length?>? sideLengths(String? raw, {bool allowAuto = false}) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    final tokens = splitTokens(text);
    if (tokens.isEmpty || tokens.length > 4) return null;
    final values = <Length>[];
    for (final token in tokens) {
      final value = length(token, allowAuto: allowAuto);
      if (value == null) return null;
      values.add(value);
    }
    return _expand4(values);
  }

  /// 解析颜色。
  ///
  /// 支持 `#rgb`／`#rrggbb`／`#rrggbbaa`、`rgb()`／`rgba()`、常见具名色、
  /// `transparent` 和 `currentColor`。`inherit` 等关键字返回 null，由层叠处理。
  static ColorValue? color(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    if (text == 'currentcolor') return ColorValue.current;
    if (text == 'transparent') return const ColorValue(0x00000000, source: 'transparent');
    if (text == 'inherit' || text == 'initial' || text == 'unset') return null;
    if (text.startsWith('#')) return _hexColor(text);
    if (text.startsWith('rgb')) return _rgbColor(text);
    final named = _namedColors[text];
    return named == null ? null : ColorValue(named, source: text);
  }

  /// 在一段可能有多项的值里找第一个颜色（`background: #eee url(...)`）。
  static ColorValue? colorInTokens(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    // 渐变/函数里的颜色不算背景色本身，先按空格切再逐个尝试。
    for (final token in splitTokens(text)) {
      final value = color(token);
      if (value != null) return value;
    }
    return null;
  }

  /// 解析字号。
  static FontSizeSpec? fontSize(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    final keyword = _fontSizeKeywords[text];
    if (keyword != null) return RelativeFontSize(_clampFont(keyword));
    final quantity = _quantity(text);
    if (quantity == null) return null;
    return switch (quantity.unit) {
      'em' => RelativeFontSize(_clampFont(quantity.value)),
      '%' => RelativeFontSize(_clampFont(quantity.value / 100)),
      'rem' => RemFontSize(_clampFont(quantity.value)),
      'px' => quantity.value > 0 ? AbsoluteFontSize(quantity.value) : null,
      'pt' => quantity.value > 0 ? AbsoluteFontSize(quantity.value * 4 / 3) : null,
      _ => null,
    };
  }

  /// 行高：`normal`、无单位数字、长度、百分比。
  static LineHeightSpec? lineHeight(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    if (text == 'normal') return const NormalLineHeight();
    final number = double.tryParse(text);
    if (number != null) {
      return number > 0 ? FactorLineHeight(number) : null;
    }
    final quantity = _quantity(text);
    if (quantity != null && quantity.unit == '%') {
      return quantity.value > 0 ? PercentLineHeight(quantity.value / 100) : null;
    }
    final length = StyleParser.length(text);
    return length == null ? null : LengthLineHeight(length);
  }

  /// 字重：`normal`／`bold`／`bolder`／`lighter`／100～900。
  static FontWeightSpec? fontWeight(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    switch (text) {
      case 'normal':
        return FontWeightSpec.normal;
      case 'bold':
        return FontWeightSpec.bold;
      case 'bolder':
        return const FontWeightSpec(700, mode: FontWeightMode.bolder);
      case 'lighter':
        return const FontWeightSpec(400, mode: FontWeightMode.lighter);
    }
    final numeric = double.tryParse(text);
    if (numeric == null || numeric <= 0) return null;
    final steps = (numeric / 100).round().clamp(1, 9);
    return FontWeightSpec(steps * 100);
  }

  static FontStyleSpecValue? fontStyle(String? raw) {
    return switch (_normalize(raw)) {
      'normal' => FontStyleSpecValue.normal,
      'italic' => FontStyleSpecValue.italic,
      'oblique' => FontStyleSpecValue.oblique,
      _ => null,
    };
  }

  /// 块级对齐。`start`／`end` 在 LTR 里分别等同左／右，但保留原值以便以后支持竖排。
  static TextAlignSpec? textAlign(String? raw) {
    return switch (_normalize(raw)) {
      'auto' => TextAlignSpec.auto,
      'left' => TextAlignSpec.left,
      'right' => TextAlignSpec.right,
      'center' => TextAlignSpec.center,
      'justify' => TextAlignSpec.justify,
      'justify-all' => TextAlignSpec.justifyAll,
      'start' => TextAlignSpec.start,
      'end' => TextAlignSpec.end,
      _ => null,
    };
  }

  static TextTransformSpec? textTransform(String? raw) {
    return switch (_normalize(raw)) {
      'none' => TextTransformSpec.none,
      'capitalize' => TextTransformSpec.capitalize,
      'uppercase' => TextTransformSpec.uppercase,
      'lowercase' => TextTransformSpec.lowercase,
      _ => null,
    };
  }

  static WhiteSpaceSpec? whiteSpace(String? raw) {
    return switch (_normalize(raw)) {
      'normal' => WhiteSpaceSpec.normal,
      'pre' => WhiteSpaceSpec.pre,
      'pre-wrap' => WhiteSpaceSpec.preWrap,
      'pre-line' => WhiteSpaceSpec.preLine,
      'nowrap' => WhiteSpaceSpec.nowrap,
      'break-spaces' => WhiteSpaceSpec.breakSpaces,
      _ => null,
    };
  }

  /// `display`。不认识的值返回 null（覆盖报告里会记成「未支持」），不猜成 block。
  static DisplaySpec? display(String? raw) {
    return switch (_normalize(raw)) {
      'block' => DisplaySpec.block,
      'inline' => DisplaySpec.inline,
      'inline-block' => DisplaySpec.inlineBlock,
      'list-item' => DisplaySpec.listItem,
      'table' => DisplaySpec.table,
      'inline-table' => DisplaySpec.inlineTable,
      'table-row-group' => DisplaySpec.tableRowGroup,
      'table-header-group' => DisplaySpec.tableHeaderGroup,
      'table-footer-group' => DisplaySpec.tableFooterGroup,
      'table-row' => DisplaySpec.tableRow,
      'table-cell' => DisplaySpec.tableCell,
      'table-caption' => DisplaySpec.tableCaption,
      'table-column-group' => DisplaySpec.tableColumnGroup,
      'table-column' => DisplaySpec.tableColumn,
      'flex' => DisplaySpec.flex,
      'inline-flex' => DisplaySpec.inlineFlex,
      'grid' => DisplaySpec.grid,
      'inline-grid' => DisplaySpec.inlineGrid,
      'flow-root' => DisplaySpec.flowRoot,
      'none' => DisplaySpec.none,
      'contents' => DisplaySpec.contents,
      _ => null,
    };
  }

  /// 上下标是我们唯一会真正偏移的写法，其余关键字先记录。
  static VerticalAlignSpec? verticalAlign(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    const keywords = {
      'baseline',
      'sub',
      'super',
      'text-top',
      'text-bottom',
      'middle',
      'top',
      'bottom',
    };
    if (keywords.contains(text)) return VerticalAlignKeyword(text);
    final length = StyleParser.length(text);
    return length == null ? null : VerticalAlignLength(length);
  }

  /// 文字装饰：`none` 与「写了什么线」是两件事，必须区分。
  ///
  /// `text-decoration: none` 表示**明确取消**链接默认的下划线；没写则不能取消。
  static TextDecorationSpec? textDecoration(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    if (text == 'none') return TextDecorationSpec.none;
    var lines = <TextDecorationLine>{};
    ColorValue? color;
    TextDecorationLineStyle? style;
    Length? thickness;
    for (final token in splitTokens(text)) {
      switch (token) {
        case 'underline':
          lines.add(TextDecorationLine.underline);
          continue;
        case 'overline':
          lines.add(TextDecorationLine.overline);
          continue;
        case 'line-through':
          lines.add(TextDecorationLine.lineThrough);
          continue;
        case 'blink':
          lines.add(TextDecorationLine.blink);
          continue;
      }
      final parsedColor = StyleParser.color(token);
      if (parsedColor != null) {
        color = parsedColor;
        continue;
      }
      final lineStyle = _decorationStyle(token);
      if (lineStyle != null) {
        style = lineStyle;
        continue;
      }
      final parsedLength = StyleParser.length(token);
      if (parsedLength != null) thickness = parsedLength;
    }
    if (lines.isEmpty) return null;
    return TextDecorationSpec(
      lines: lines,
      color: color,
      style: style,
      thickness: thickness,
    );
  }

  /// `url(...)` 里的地址；外网地址返回 null（离线引擎只认书内资源）。
  static String? url(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty) return null;
    final match = RegExp(
      r'''url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)''',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final value = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim();
    if (value.isEmpty) return null;
    if (value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('//') ||
        value.startsWith('data:')) {
      return null;
    }
    return value;
  }

  /// 单个关键字；多个词或空值返回 null。
  static String? keyword(String? raw) {
    final text = _normalize(raw);
    if (text.isEmpty || text.contains(' ')) return null;
    return text;
  }

  static TextDecorationLineStyle? _decorationStyle(String token) {
    return switch (token) {
      'solid' => TextDecorationLineStyle.solid,
      'double' => TextDecorationLineStyle.double,
      'dotted' => TextDecorationLineStyle.dotted,
      'dashed' => TextDecorationLineStyle.dashed,
      'wavy' => TextDecorationLineStyle.wavy,
      _ => null,
    };
  }

  /// 去掉首尾空白并转小写；注释已经被上层剥掉了。
  static String _normalize(String? raw) => (raw ?? '').trim().toLowerCase();

  /// 拆出「数字 + 单位」。`calc()`、`min()` 等函数在这里返回 null，
  /// 表示我们不会猜它的结果。
  static ({double value, String unit})? _quantity(String token) {
    final match = RegExp(
      r'^([+-]?(?:\d+\.?\d*|\.\d+))\s*(em|rem|%|px|pt)?$',
    ).firstMatch(token);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    return (value: value, unit: match.group(2) ?? '');
  }

  /// 按空白切词，括号里的内容不拆开（`url(a b.png)` 算一个词）。
  static List<String> splitTokens(String text) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var depth = 0;
    var quote = '';
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quote.isNotEmpty) {
        buffer.write(char);
        if (char == quote) quote = '';
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
        buffer.write(char);
        continue;
      }
      if (char == '(') depth++;
      if (char == ')') depth = depth > 0 ? depth - 1 : 0;
      if (depth == 0 && (char == ' ' || char == '\t' || char == '\n')) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        continue;
      }
      buffer.write(char);
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }

  /// 按顶层逗号切分（多层阴影、多层背景）。
  static List<String> splitLayers(String text) {
    final layers = <String>[];
    final buffer = StringBuffer();
    var depth = 0;
    var quote = '';
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quote.isNotEmpty) {
        buffer.write(char);
        if (char == quote) quote = '';
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
        buffer.write(char);
        continue;
      }
      if (char == '(') depth++;
      if (char == ')') depth = depth > 0 ? depth - 1 : 0;
      if (depth == 0 && char == ',') {
        layers.add(buffer.toString().trim());
        buffer.clear();
        continue;
      }
      buffer.write(char);
    }
    if (buffer.isNotEmpty) layers.add(buffer.toString().trim());
    return layers;
  }

  static double _clampFont(double factor) =>
      factor.clamp(_minFontFactor, _maxFontFactor);

  static List<Length?> _expand4(List<Length> values) {
    return switch (values.length) {
      1 => [values[0], values[0], values[0], values[0]],
      2 => [values[0], values[1], values[0], values[1]],
      3 => [values[0], values[1], values[2], values[1]],
      _ => [values[0], values[1], values[2], values[3]],
    };
  }

  static ColorValue? _hexColor(String text) {
    final hex = text.substring(1);
    if (hex.length == 3) {
      final r = int.tryParse(hex[0] * 2, radix: 16);
      final g = int.tryParse(hex[1] * 2, radix: 16);
      final b = int.tryParse(hex[2] * 2, radix: 16);
      if (r == null || g == null || b == null) return null;
      return ColorValue(0xFF000000 | (r << 16) | (g << 8) | b, source: text);
    }
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      return value == null ? null : ColorValue(0xFF000000 | value, source: text);
    }
    // CSS 的 #rrggbbaa：前 6 位是颜色，后 2 位是透明度。
    if (hex.length == 8) {
      final rgb = int.tryParse(hex.substring(0, 6), radix: 16);
      final alpha = int.tryParse(hex.substring(6), radix: 16);
      if (rgb == null || alpha == null) return null;
      return ColorValue((alpha << 24) | rgb, source: text);
    }
    return null;
  }

  static ColorValue? _rgbColor(String text) {
    final match = RegExp(
      r'^rgba?\(([0-9.]+)[,\s]+([0-9.]+)[,\s]+([0-9.]+)(?:[,\s/]+([0-9.]+%?))?\)$',
    ).firstMatch(text);
    if (match == null) return null;
    final r = double.tryParse(match.group(1)!)?.round().clamp(0, 255);
    final g = double.tryParse(match.group(2)!)?.round().clamp(0, 255);
    final b = double.tryParse(match.group(3)!)?.round().clamp(0, 255);
    if (r == null || g == null || b == null) return null;
    var alpha = 255;
    final rawAlpha = match.group(4);
    if (rawAlpha != null) {
      final value = double.tryParse(rawAlpha.replaceAll('%', ''));
      if (value != null) {
        alpha = rawAlpha.endsWith('%')
            ? (value / 100 * 255).round().clamp(0, 255)
            : (value * 255).round().clamp(0, 255);
      }
    }
    return ColorValue((alpha << 24) | (r << 16) | (g << 8) | b, source: text);
  }
}
