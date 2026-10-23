import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import 'measured_block.dart';

/// 仅编码已完成的测量数据，不持有绘图句柄。格式变化同时变更缓存身份版本。
abstract final class MeasuredBlockCodec {
  static Map<String, Object?> encode(MeasuredBlock b) => {
    'id': b.blockId,
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
        ],
    ],
    'lines': [
      for (final l in b.lines)
        [l.start, l.end, l.height, l.width, l.hyphenated],
    ],
    'height': b.height,
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
    'layoutWidth': b.layoutWidth,
  };

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
        ),
      );
    }
    final image = j['image'] as List?, bounds = j['bounds'] as List?;
    return MeasuredBlock(
      blockId: j['id'] as String,
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
            );
          })(),
      ],
      lines: lines,
      height: number(j['height']),
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
      layoutWidth: j['layoutWidth'] == null ? null : number(j['layoutWidth']),
    );
  }
}
