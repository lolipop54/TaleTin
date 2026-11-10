/// 盒模型相关的样式值解析：边框、背景、阴影、圆角、列表标记。
///
/// 和 [property_parsers.dart] 分开的原因只有一个：文件别太长，两边职责不同。
/// 这一半处理「一个声明里带好几个值」的简写（`border: 1px solid #ccc`、
/// `box-shadow: 0 2px 4px #000`），需要按顺序挑出宽度、线型、颜色。
library;

import 'property_parsers.dart';
import 'style_box_value.dart';
import 'style_value.dart';

/// 边框没写宽度时用的默认宽度。
///
/// CSS 的 `medium` 是 3px；引擎历史实现按 0.01em 画（几乎是一条发丝线）。
/// 迁移期先按 1px 落地，等 P5 用真实样书对照后再决定是否改成 3px。
const Length kDefaultBorderWidth = PxLength(1);

/// `thin`／`medium`／`thick` 对应的宽度（CSS 规范建议值）。
const Map<String, double> _borderWidthKeywords = {
  'thin': 1,
  'medium': 3,
  'thick': 5,
};

abstract final class BoxStyleParser {
  /// 四边边框（`border`／`border-top` 等简写）。
  static BorderSpec? border(String? raw) {
    final side = borderSide(raw);
    return side == null ? null : BorderSpec.all(side);
  }

  /// 单边边框：`<宽度> || <线型> || <颜色>`，顺序任意。
  static BorderSideSpec? borderSide(String? raw) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    Length? width;
    BorderLineStyle? style;
    ColorValue? color;
    for (final token in StyleParser.splitTokens(text)) {
      final lineStyle = borderLineStyle(token);
      if (lineStyle != null) {
        style = lineStyle;
        continue;
      }
      final parsedColor = StyleParser.color(token);
      if (parsedColor != null) {
        color = parsedColor;
        continue;
      }
      final keywordWidth = _borderWidthKeywords[token];
      if (keywordWidth != null) {
        width = PxLength(keywordWidth);
        continue;
      }
      final parsedLength = StyleParser.length(token);
      if (parsedLength != null) width = parsedLength;
    }
    if (style == null && width == null && color == null) return null;
    return BorderSideSpec(width: width, style: style, color: color);
  }

  static BorderLineStyle? borderLineStyle(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'none' => BorderLineStyle.none,
      'hidden' => BorderLineStyle.hidden,
      'solid' => BorderLineStyle.solid,
      'dashed' => BorderLineStyle.dashed,
      'dotted' => BorderLineStyle.dotted,
      'double' => BorderLineStyle.double,
      'groove' => BorderLineStyle.groove,
      'ridge' => BorderLineStyle.ridge,
      'inset' => BorderLineStyle.inset,
      'outset' => BorderLineStyle.outset,
      _ => null,
    };
  }

  /// `border-width: 1px 0` → 只带宽度、四边展开的边框。
  ///
  /// 只填自己写的字段，其余留空：层叠时才能做到「`border` 先写宽度和线型、
  /// `border-color` 后写颜色」互不覆盖。
  static BorderSpec? borderWidths(String? raw) => _sideSpecs(
    raw,
    (token) {
      final keyword = _borderWidthKeywords[token];
      if (keyword != null) return BorderSideSpec(width: PxLength(keyword));
      final length = StyleParser.length(token);
      return length == null ? null : BorderSideSpec(width: length);
    },
  );

  static BorderSpec? borderStyles(String? raw) => _sideSpecs(
    raw,
    (token) {
      final style = borderLineStyle(token);
      return style == null ? null : BorderSideSpec(style: style);
    },
  );

  static BorderSpec? borderColors(String? raw) => _sideSpecs(
    raw,
    (token) {
      final color = StyleParser.color(token);
      return color == null ? null : BorderSideSpec(color: color);
    },
  );

  /// 背景简写。
  ///
  /// 第一版真正被绘制层消费的只有颜色；图片地址会保留下来（本地资源），
  /// 重复方式按关键字识别，位置和尺寸先原样留 [BackgroundSpec.raw]，
  /// 等背景图真的实现时再解析，避免现在猜一套用不上的语义。
  static BackgroundSpec? background(String? raw) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    final layers = StyleParser.splitLayers(text);
    final first = layers.first;
    ColorValue? color;
    String? imageUrl;
    String? gradient;
    String? repeat;
    String? position;
    String? size;
    String? clip;
    var leftover = false;
    for (final token in StyleParser.splitTokens(first)) {
      if (token.startsWith('url(')) {
        imageUrl = StyleParser.url(token);
        continue;
      }
      if (token.contains('gradient(')) {
        gradient = token;
        continue;
      }
      if (_repeatKeywords.contains(token)) {
        repeat = token;
        continue;
      }
      if (_positionKeywords.contains(token)) {
        position = position == null ? token : '$position $token';
        continue;
      }
      if (token == 'cover' || token == 'contain') {
        size = token;
        continue;
      }
      if (_clipKeywords.contains(token)) {
        clip = token;
        continue;
      }
      final parsedColor = StyleParser.color(token);
      if (parsedColor != null && color == null) {
        color = parsedColor;
        continue;
      }
      // 还认不出的写法（多层背景、尺寸、attachment 等）原样记进 raw。
      leftover = true;
    }
    final spec = BackgroundSpec(
      color: color,
      imageUrl: imageUrl,
      imageGradient: gradient,
      repeat: repeat,
      position: position,
      size: size,
      clip: clip,
      raw: leftover || layers.length > 1 ? text : null,
    );
    return spec.isEmpty ? null : spec;
  }

  static BackgroundSpec? backgroundColor(String? raw) {
    final color = StyleParser.color(raw);
    return color == null ? null : BackgroundSpec(color: color);
  }

  static BackgroundSpec? backgroundImage(String? raw) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty || text == 'none') return null;
    final url = StyleParser.url(text);
    if (url != null) return BackgroundSpec(imageUrl: url);
    if (text.contains('gradient(')) {
      return BackgroundSpec(imageGradient: text, raw: text);
    }
    return null;
  }

  /// 阴影：`text-shadow` 和 `box-shadow` 共用解析，区别只在允不允许 spread。
  static List<ShadowValue>? shadows(String? raw, {bool allowSpread = true}) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty || text == 'none') return null;
    final result = <ShadowValue>[];
    for (final layer in StyleParser.splitLayers(text)) {
      var inset = false;
      ColorValue? color;
      final lengths = <Length>[];
      for (final token in StyleParser.splitTokens(layer)) {
        if (token == 'inset') {
          inset = true;
          continue;
        }
        final parsedColor = StyleParser.color(token);
        if (parsedColor != null) {
          color = parsedColor;
          continue;
        }
        final parsedLength = StyleParser.length(token);
        if (parsedLength != null) lengths.add(parsedLength);
      }
      // 至少要有 x、y 两个偏移，否则这一层是无效写法，跳过但不影响其它层。
      if (lengths.length < 2) continue;
      result.add(
        ShadowValue(
          offsetX: lengths[0],
          offsetY: lengths[1],
          blur: lengths.length > 2 ? lengths[2] : null,
          spread: allowSpread && lengths.length > 3 ? lengths[3] : null,
          color: color,
          inset: inset,
        ),
      );
    }
    return result.isEmpty ? null : result;
  }

  /// 圆角：`10px`、`10px 4px`、`10px / 20px`（椭圆写法只取横向值并记录）。
  static CornerRadii? radii(String? raw) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    final horizontal = text.split('/').first.trim();
    final sides = StyleParser.sideLengths(horizontal);
    if (sides == null) return null;
    return CornerRadii(
      topLeft: sides[0],
      topRight: sides[1],
      bottomRight: sides[2],
      bottomLeft: sides[3],
    );
  }

  static ListStyleType? listStyleType(String? raw) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'none') return ListStyleType.none;
    if (text.startsWith('decimal-leading-zero')) {
      return ListStyleType.decimalLeadingZero;
    }
    if (text.startsWith('decimal')) return ListStyleType.decimal;
    if (text.startsWith('lower-alpha') || text.startsWith('lower-latin')) {
      return ListStyleType.lowerAlpha;
    }
    if (text.startsWith('upper-alpha') || text.startsWith('upper-latin')) {
      return ListStyleType.upperAlpha;
    }
    if (text.startsWith('lower-greek')) return ListStyleType.lowerGreek;
    if (text.startsWith('lower-roman')) return ListStyleType.lowerRoman;
    if (text.startsWith('upper-roman')) return ListStyleType.upperRoman;
    if (text.startsWith('disc')) return ListStyleType.disc;
    if (text.startsWith('circle')) return ListStyleType.circle;
    if (text.startsWith('square')) return ListStyleType.square;
    return null;
  }

  static ListStylePosition? listStylePosition(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'inside' => ListStylePosition.inside,
      'outside' => ListStylePosition.outside,
      _ => null,
    };
  }

  /// `list-style` 简写：`none`、`circle inside`、`url(x.png) square` 等。
  static ListStyleSpec? listStyle(String? raw) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    ListStyleType? type;
    ListStylePosition? position;
    String? imageUrl;
    for (final token in StyleParser.splitTokens(text)) {
      if (token.startsWith('url(')) {
        imageUrl = StyleParser.url(token);
        continue;
      }
      final parsedPosition = listStylePosition(token);
      if (parsedPosition != null) {
        position = parsedPosition;
        continue;
      }
      final parsedType = listStyleType(token);
      if (parsedType != null) type = parsedType;
    }
    if (type == null && position == null && imageUrl == null) return null;
    return ListStyleSpec(type: type, position: position, imageUrl: imageUrl);
  }

  static BoxSizingSpec? boxSizing(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'content-box' => BoxSizingSpec.contentBox,
      'border-box' => BoxSizingSpec.borderBox,
      _ => null,
    };
  }

  static FloatSpec? float(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'none' => FloatSpec.none,
      'left' => FloatSpec.left,
      'right' => FloatSpec.right,
      'inline-start' => FloatSpec.inlineStart,
      'inline-end' => FloatSpec.inlineEnd,
      _ => null,
    };
  }

  static ClearSpec? clear(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'none' => ClearSpec.none,
      'left' => ClearSpec.left,
      'right' => ClearSpec.right,
      'both' => ClearSpec.both,
      _ => null,
    };
  }

  static PositionSpec? position(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'static' => PositionSpec.static,
      'relative' => PositionSpec.relative,
      'absolute' => PositionSpec.absolute,
      'fixed' => PositionSpec.fixed,
      'sticky' => PositionSpec.sticky,
      _ => null,
    };
  }

  /// 把 `1`～`4` 个值展开成四边，每一项用 [parse] 转换；任何一项非法就整条丢弃。
  static BorderSpec? _sideSpecs(
    String? raw,
    BorderSideSpec? Function(String token) parse,
  ) {
    final text = (raw ?? '').trim().toLowerCase();
    if (text.isEmpty) return null;
    final tokens = StyleParser.splitTokens(text);
    if (tokens.isEmpty || tokens.length > 4) return null;
    final sides = <BorderSideSpec>[];
    for (final token in tokens) {
      final side = parse(token);
      if (side == null) return null;
      sides.add(side);
    }
    final expanded = switch (sides.length) {
      1 => [sides[0], sides[0], sides[0], sides[0]],
      2 => [sides[0], sides[1], sides[0], sides[1]],
      3 => [sides[0], sides[1], sides[2], sides[1]],
      _ => [sides[0], sides[1], sides[2], sides[3]],
    };
    return BorderSpec(
      top: expanded[0],
      right: expanded[1],
      bottom: expanded[2],
      left: expanded[3],
    );
  }

  static const _repeatKeywords = {
    'repeat',
    'repeat-x',
    'repeat-y',
    'no-repeat',
    'space',
    'round',
  };

  static const _positionKeywords = {
    'left',
    'right',
    'top',
    'bottom',
    'center',
  };

  static const _clipKeywords = {
    'border-box',
    'padding-box',
    'content-box',
    'text',
  };
}
