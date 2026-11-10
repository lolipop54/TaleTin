import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import 'measured_block.dart';
import 'math_formula.dart';
import 'background_image_style.dart';

/// 仅编码已完成的测量数据，不持有绘图句柄。格式变化同时变更缓存身份版本。
abstract final class MeasuredBlockCodec {
  static Map<String, Object?> encode(MeasuredBlock b) => {
    'id': b.blockId,
    if (b.decorationAtStart) 'leadingDecoration': true,
    'kind': b.kind.code,
    'level': b.level,
    'text': b.text,
    'runs': [for (final r in b.runs) r.toJson()],
    'styles': [
      for (final s in b.runStyles)
        [
          s.fontFamily,
          s.fontSize,
          s.fontWeight?.value,
          s.fontStyle?.index,
          s.height,
          // 文字装饰：0 无、1 下划线、2 删除线、3 两者都有
          s.decoration == null
              ? 0
              : (s.decoration!.contains(TextDecoration.underline) ? 1 : 0) |
                    (s.decoration!.contains(TextDecoration.lineThrough)
                        ? 2
                        : 0),
          // 书里给的文字颜色：漏存会让重开后的文字退回主题黑字
          // （真机：红底白字的章题重开后变成黑字）
          s.color?.toARGB32(),
          s.letterSpacing,
          s.wordSpacing,
          s.shadows == null
              ? null
              : [
                  for (final shadow in s.shadows!) ...[
                    shadow.offset.dx,
                    shadow.offset.dy,
                    shadow.blurRadius,
                    shadow.color.toARGB32(),
                  ],
                ],
          if (s.fontFamilyFallback != null || s.fontVariations != null)
            s.fontFamilyFallback,
          if (s.fontVariations != null)
            [
              for (final variation in s.fontVariations!)
                [variation.axis, variation.value],
            ],
        ],
    ],
    'lines': [
      for (final l in b.lines)
        [
          l.start,
          l.end,
          l.height,
          l.width,
          l.hyphenated,
          l.hardBreak,
          l.left,
          l.textTop,
          [
            for (final s in l.segments)
              [
                s.start,
                s.end,
                s.left,
                s.width,
                s.letterSpacing,
                s.top,
                s.baseline,
              ],
          ],
        ],
    ],
    'inlineImages': [
      for (final image in b.inlineImages)
        [
          image.offset,
          image.line,
          image.left,
          image.top,
          image.size.width,
          image.size.height,
          image.resourcePath,
          image.alt,
          image.formula?.toJson(),
        ],
    ],
    'box': b.box == null ? null : _encodeBox(b.box!),
    'containers': [
      for (final container in b.containerBoxes)
        [
          container.elementId,
          _encodeBox(container.box),
          container.first,
          container.last,
          container.left,
          container.width,
          container.top,
          container.height,
          container.bottom,
          container.lineFrom,
          container.lineTo,
        ],
    ],
    'inlineBoxes': [
      for (final p in b.inlineBoxes)
        {
          'span': p.span.toJson(),
          'box': _encodeBox(p.box),
          'line': p.line,
          'rect': [p.rect.left, p.rect.top, p.rect.width, p.rect.height],
          'first': p.first,
          'last': p.last,
        },
    ],
    'boxId': b.boxId,
    'codeBox': b.codeBox == null ? null : _encodeBox(b.codeBox!),
    'codeTop': b.codeTop,
    'codeBottom': b.codeBottom,
    'boxIndent': b.boxIndent,
    'line': b.line,
    'bodyTop': b.bodyTop,
    'bodyBottom': b.bodyBottom,
    'marginTop': b.marginTop,
    'marginBottom': b.marginBottom,
    'boxFirst': b.boxFirst,
    'boxLast': b.boxLast,
    'textShadows': b.textStyle.shadows == null
        ? null
        : [
            for (final shadow in b.textStyle.shadows!) ...[
              shadow.offset.dx,
              shadow.offset.dy,
              shadow.blurRadius,
              shadow.color.toARGB32(),
            ],
          ],
    'align': b.align,
    'marker': b.marker,
    'markerInset': b.markerInset,
    'justify': b.justify,
    'script': b.hasScript,
    'height': b.height,
    'pageTop': b.pageTop,
    'image': b.imageSize == null
        ? null
        : [b.imageSize!.width, b.imageSize!.height],
    'resource': b.resourcePath,
    'alt': b.alt,
    'inset': b.inset,
    'decoration': b.isDecoration,
    'title': b.isTitleDecoration,
    'prefix': b.displayPrefixLength,
    'tableId': b.tableId,
    'bounds': b.tableBounds == null
        ? null
        : [
            b.tableBounds!.left,
            b.tableBounds!.top,
            b.tableBounds!.width,
            b.tableBounds!.height,
          ],
    'tableTop': b.tableTop,
    'tableUnit': b.tableUnit,
    'tableHeader': b.tableHeader,
    // 引用块里的表格：盒子本身不能丢，否则重开章节后只剩文字、没有背景边框
    'tableBox': b.tableBox == null ? null : _encodeBox(b.tableBox!),
    'layoutWidth': b.layoutWidth,
  };

  /// 盒子编码：四边颜色分开存，不能再合成一个颜色。
  ///
  /// 顺序：背景、上／右／下／左颜色、上／右／下／左宽度、圆角、四边内边距、
  /// 阴影个数与阴影、四边线型。格式变化时 `measured-prefix` 会一起升级，
  /// 旧断点不会被误读。
  static List<Object?> _encodeBox(BlockBox box) => [
    box.background?.toARGB32() ?? 0,
    box.borderColors[0].toARGB32(),
    box.borderColors[1].toARGB32(),
    box.borderColors[2].toARGB32(),
    box.borderColors[3].toARGB32(),
    box.borderTop,
    box.borderRight,
    box.borderBottom,
    box.borderLeft,
    [
      box.borderRadius.topLeft.x,
      box.borderRadius.topRight.x,
      box.borderRadius.bottomRight.x,
      box.borderRadius.bottomLeft.x,
    ],
    box.padTop,
    box.padRight,
    box.padBottom,
    box.padLeft,
    // 阴影个数：必须显式写下，否则解码时会把后面的边框线型当成阴影
    // （实测：缓存的虚线框重新打开后变成实线）
    box.shadows.length,
    for (final shadow in box.shadows) ...[
      shadow.offset.dx,
      shadow.offset.dy,
      shadow.blurRadius,
      shadow.color.toARGB32(),
      shadow.spreadRadius,
    ],
    ...box.borderStyles,
    box.backgroundImage?.toJson(),
  ];

  static MeasuredBlock decode(Map<String, dynamic> j) {
    double number(Object? value) {
      final n = (value as num).toDouble();
      if (!n.isFinite) throw const FormatException('非有限排版尺寸');
      return n;
    }

    final text = j['text'] as String;
    final lines = <MeasuredLine>[];
    for (final raw in j['lines'] as List) {
      final row = raw as List;
      final start = row[0] as int, end = row[1] as int;
      if (start < 0 ||
          end < start ||
          end > text.length ||
          (lines.isNotEmpty && start != lines.last.end)) {
        throw const FormatException('测量行范围不连续');
      }
      lines.add(
        MeasuredLine(
          start: start,
          end: end,
          height: number(row[2]),
          width: number(row[3]),
          hyphenated: row[4] as bool,
          hardBreak: row.length > 5 && row[5] == true,
          left: row.length > 6 ? number(row[6]) : 0,
          textTop: row.length > 7 ? number(row[7]) : 0,
          segments: row.length > 8
              ? [
                  for (final rawSegment in row[8] as List)
                    () {
                      final segment = rawSegment as List;
                      return MeasuredSegment(
                        start: (segment[0] as num).toInt(),
                        end: (segment[1] as num).toInt(),
                        left: number(segment[2]),
                        width: number(segment[3]),
                        top: segment.length > 5 ? number(segment[5]) : 0,
                        baseline: segment.length > 6 ? number(segment[6]) : 0,
                        letterSpacing: segment.length > 4
                            ? number(segment[4])
                            : 0,
                      );
                    }(),
                ]
              : const [],
        ),
      );
    }
    final inlineImages = <InlineImagePlacement>[
      for (final raw in (j['inlineImages'] as List? ?? const []))
        (() {
          final row = raw as List;
          return InlineImagePlacement(
            offset: (row[0] as num).toInt(),
            line: (row[1] as num).toInt(),
            left: number(row[2]),
            top: number(row[3]),
            size: Size(number(row[4]), number(row[5])),
            resourcePath: row[6] as String,
            alt: row.length > 7 ? row[7] as String? : null,
            formula: row.length > 8 && row[8] is Map
                ? FormulaGeometry.fromJson(row[8] as Map)
                : null,
          );
        })(),
    ];
    final image = j['image'] as List?, bounds = j['bounds'] as List?;
    final containers = <ContainerBoxFrame>[
      for (final raw in (j['containers'] as List? ?? const []))
        (() {
          final row = raw as List;
          return ContainerBoxFrame(
            elementId: (row[0] as num).toInt(),
            box: _decodeBox(row[1] as List, number),
            first: row[2] == true,
            last: row[3] == true,
            left: number(row[4]),
            width: number(row[5]),
            top: row.length > 6 ? number(row[6]) : 0,
            height: row.length > 7 && row[7] != null ? number(row[7]) : null,
            bottom: row.length > 8 ? number(row[8]) : 0,
            lineFrom: row.length > 9 ? (row[9] as num).toInt() : 0,
            lineTo: row.length > 10 ? (row[10] as num?)?.toInt() : null,
          );
        })(),
    ];
    return MeasuredBlock(
      blockId: j['id'] as String,
      decorationAtStart: j['leadingDecoration'] == true,
      kind: BlockKind.fromCode(j['kind'] as String),
      level: j['level'] as int?,
      text: text,
      runs: [
        for (final r in j['runs'] as List)
          TextRun.fromJson(Map<String, Object?>.from(r as Map)),
      ],
      runStyles: [
        for (final raw in j['styles'] as List)
          (() {
            final s = raw as List;
            return TextStyle(
              fontFamily: s[0] as String?,
              fontSize: s[1] == null ? null : number(s[1]),
              fontWeight: s[2] == null
                  ? null
                  : FontWeight.values.firstWhere((w) => w.value == s[2]),
              fontStyle: s[3] == null ? null : FontStyle.values[s[3] as int],
              height: s[4] == null ? null : number(s[4]),
              decoration: (s.length > 5 ? (s[5] as num).toInt() : 0) == 0
                  ? null
                  : TextDecoration.combine([
                      if ((s.length > 5 ? (s[5] as num).toInt() : 0) & 1 != 0)
                        TextDecoration.underline,
                      if ((s.length > 5 ? (s[5] as num).toInt() : 0) & 2 != 0)
                        TextDecoration.lineThrough,
                    ]),
              color: s.length > 6 && s[6] != null
                  ? Color((s[6] as num).toInt())
                  : null,
              letterSpacing: s.length > 7 && s[7] != null ? number(s[7]) : null,
              wordSpacing: s.length > 8 && s[8] != null ? number(s[8]) : null,
              shadows: s.length > 9 && s[9] != null
                  ? _decodeShadows(s[9] as List, number)
                  : null,
              fontFamilyFallback: s.length > 10
                  ? (s[10] as List?)?.cast<String>()
                  : null,
              fontVariations: s.length > 11
                  ? [
                      for (final v in (s[11] as List).cast<List>())
                        FontVariation(v[0] as String, number(v[1])),
                    ]
                  : null,
            );
          })(),
      ],
      lines: lines,
      height: number(j['height']),
      pageTop: j['pageTop'] == null ? null : number(j['pageTop']),
      imageSize: image == null
          ? null
          : Size(number(image[0]), number(image[1])),
      resourcePath: j['resource'] as String?,
      alt: j['alt'] as String?,
      inset: number(j['inset']),
      isDecoration: j['decoration'] as bool,
      isTitleDecoration: j['title'] as bool,
      displayPrefixLength: j['prefix'] as int,
      tableId: j['tableId'] as String?,
      tableBounds: bounds == null
          ? null
          : Rect.fromLTWH(
              number(bounds[0]),
              number(bounds[1]),
              number(bounds[2]),
              number(bounds[3]),
            ),
      tableTop: number(j['tableTop']),
      tableUnit: number(j['tableUnit']),
      tableHeader: j['tableHeader'] as bool,
      tableBox: j['tableBox'] == null
          ? null
          : _decodeBox(j['tableBox'] as List, number),
      layoutWidth: j['layoutWidth'] == null ? null : number(j['layoutWidth']),
      box: j['box'] == null ? null : _decodeBox(j['box'] as List, number),
      boxId: (j['boxId'] as num?)?.toInt(),
      containerBoxes: containers,
      codeBox: j['codeBox'] == null
          ? null
          : _decodeBox(j['codeBox'] as List, number),
      codeTop: j['codeTop'] == null ? 0 : number(j['codeTop']),
      codeBottom: j['codeBottom'] == null ? 0 : number(j['codeBottom']),
      boxIndent: j['boxIndent'] == null ? 0 : number(j['boxIndent']),
      line: j['line'] == null
          ? null
          : [for (final value in j['line'] as List) (value as num).toInt()],
      bodyTop: j['bodyTop'] == null ? 0 : number(j['bodyTop']),
      bodyBottom: j['bodyBottom'] == null ? 0 : number(j['bodyBottom']),
      marginTop: j['marginTop'] == null ? 0 : number(j['marginTop']),
      marginBottom: j['marginBottom'] == null ? 0 : number(j['marginBottom']),
      boxFirst: j['boxFirst'] != false,
      boxLast: j['boxLast'] != false,
      textStyle: BlockTextStyle(
        shadows: j['textShadows'] == null
            ? null
            : _decodeShadows(j['textShadows'] as List, number),
      ),
      align: j['align'] as String?,
      marker: j['marker'] as String?,
      markerInset: j['markerInset'] == null ? 0 : number(j['markerInset']),
      justify: j['justify'] == true,
      hasScript: j['script'] == true,
      inlineImages: inlineImages,
      inlineBoxes: [
        for (final raw in (j['inlineBoxes'] as List? ?? const []))
          (() {
            final p = raw as Map, r = p['rect'] as List;
            return InlineBoxPlacement(
              span: InlineBoxSpan.fromJson(
                Map<String, Object?>.from(p['span'] as Map),
              ),
              box: _decodeBox(p['box'] as List, number),
              line: p['line'] as int,
              rect: Rect.fromLTWH(
                number(r[0]),
                number(r[1]),
                number(r[2]),
                number(r[3]),
              ),
              first: p['first'] as bool,
              last: p['last'] as bool,
            );
          })(),
      ],
    );
  }

  static BlockBox _decodeBox(List raw, double Function(Object?) number) {
    Color color(int value) => Color(value);
    final shadowCount = raw.length > 14
        ? (raw[14] as num).toInt().clamp(0, 8)
        : 0;
    final shadows = <BoxShadow>[];
    for (var i = 0; i < shadowCount; i++) {
      final base = 15 + i * 5;
      if (base + 3 >= raw.length) break;
      shadows.add(
        BoxShadow(
          offset: Offset(number(raw[base]), number(raw[base + 1])),
          blurRadius: number(raw[base + 2]),
          color: Color((raw[base + 3] as num).toInt()),
          spreadRadius: number(raw[base + 4]),
        ),
      );
    }
    final styleBase = 15 + shadowCount * 5;
    return BlockBox(
      backgroundImage: raw.length > styleBase + 4
          ? BookBackgroundImage.fromJson(raw[styleBase + 4])
          : null,
      background: (raw[0] as num).toInt() == 0
          ? null
          : color((raw[0] as num).toInt()),
      borderColors: [
        color((raw[1] as num).toInt()),
        color((raw[2] as num).toInt()),
        color((raw[3] as num).toInt()),
        color((raw[4] as num).toInt()),
      ],
      borderTop: number(raw[5]),
      borderRight: number(raw[6]),
      borderBottom: number(raw[7]),
      borderLeft: number(raw[8]),
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(number((raw[9] as List)[0])),
        topRight: Radius.circular(number((raw[9] as List)[1])),
        bottomRight: Radius.circular(number((raw[9] as List)[2])),
        bottomLeft: Radius.circular(number((raw[9] as List)[3])),
      ),
      padTop: number(raw[10]),
      padRight: number(raw[11]),
      padBottom: number(raw[12]),
      padLeft: number(raw[13]),
      shadows: shadows,
      borderStyles: [
        for (var i = styleBase; i < styleBase + 4; i++)
          if (i < raw.length) (raw[i] as num).toInt() else 1,
      ],
    );
  }

  static List<Shadow> _decodeShadows(
    List raw,
    double Function(Object?) number,
  ) => [
    for (var i = 0; i + 3 < raw.length; i += 4)
      Shadow(
        offset: Offset(number(raw[i]), number(raw[i + 1])),
        blurRadius: number(raw[i + 2]),
        color: Color((raw[i + 3] as num).toInt()),
      ),
  ];
}
