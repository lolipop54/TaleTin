import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import 'computed_style.dart';
import 'computed_style_json.dart';
import 'style_value.dart';
import 'style_box_value.dart';

/// 读者字号表示普通正文的大小。作者的正文倍率只用于确定基准，标题、
/// 小字及盒子仍保留相对于这个基准的比例；不能拿扉页书名当普通正文。
abstract final class PublicationTypography {
  static double fontBasis(
    ChapterContent content,
    DisplaySourceIndex source,
    Map<int, ComputedStyle> styles,
  ) {
    var longest = 0;
    var basis = 1.0;
    for (var i = 0; i < content.blocks.length; i++) {
      final block = content.blocks[i];
      final owner = source.ownerOfBlock(i);
      if (owner?.tag != 'p' || block.kind != BlockKind.paragraph) continue;
      final style = styles[owner!.id] ?? ComputedStyle.empty;
      if (style.block.textAlign == TextAlignSpec.center ||
          style.block.textAlign == TextAlignSpec.right ||
          source
              .chainOfBlock(i)
              .any(
                (e) => const {
                  'table',
                  'nav',
                  'figure',
                  'blockquote',
                  'aside',
                }.contains(e.tag),
              )) {
        continue;
      }
      final text = block.runs.map((r) => r.text).join().trim();
      // 短段可能是书名、署名或目录。只用足够长的普通正文确定基准。
      if (text.length < 80 || text.length <= longest) continue;
      final size = style.text.fontSize;
      if (size != null && size is! RelativeFontSize) continue;
      longest = text.length;
      basis = size is RelativeFontSize ? size.factor : 1;
    }
    return basis;
  }

  static ComputedStyle normalize(ComputedStyle style, double basis) {
    if (basis == 1) return style;
    // rem 也属于原书根字号。把它的系数一起换算，避免文字缩小后
    // 边框、留白仍沿用旧根字号；px 与百分比不随字号基准改变。
    Object? rems(Object? value) {
      if (value is Map) {
        return {
          for (final entry in value.entries)
            entry.key: value['u'] == 'rem' && entry.key == 'v'
                ? (entry.value as num) / basis
                : rems(entry.value),
        };
      }
      if (value is List) return value.map(rems).toList();
      return value;
    }

    final json = Map<String, Object?>.from(
      rems(computedStyleToJson(style)) as Map,
    );
    final text = Map<String, Object?>.from(json['t'] as Map? ?? {});
    final size = style.text.fontSize;
    if (size == null || size is RelativeFontSize) {
      text['fs'] = RelativeFontSize(
        (size is RelativeFontSize ? size.factor : 1) / basis,
      ).toJson();
    }
    json['t'] = text;
    return computedStyleFromJson(json);
  }

  /// 有些出版物用 p 写章节标题。只识别明确放大、全段加粗且作者取消
  /// 缩进的短段；普通加粗正文、正文统一放大和只有首词加粗均不算标题。
  static bool isHeading(
    ContentBlock block,
    ComputedStyle own,
    Iterable<ComputedStyle> runs,
  ) {
    final size = own.text.fontSize;
    final text = block.runs.map((r) => r.text).join().trim();
    final indent = own.block.textIndent;
    return block.kind == BlockKind.paragraph &&
        size is RelativeFontSize &&
        size.factor >= 1.2 &&
        indent != null &&
        !indent.isAuto &&
        indent.resolve(
              const LengthContext(fontSize: 1, rootFontSize: 1, reference: 1),
            ) ==
            0 &&
        text.isNotEmpty &&
        text.length <= 120 &&
        !RegExp(r'[。！？；]$').hasMatch(text) &&
        runs.isNotEmpty &&
        runs.every((s) => s.text.fontWeight?.isBold == true);
  }
}
