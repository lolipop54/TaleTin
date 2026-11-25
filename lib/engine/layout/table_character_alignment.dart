part of 'table_layout.dart';

/// 同一列的数据共用对齐字符的起点。尺寸来自最终字体的字形位置，保留原文字偏移。
class _TableCharacterAlignment {
  final _stops = <int, double>{};
  final _prefix = <MeasuredBlock, double>{};

  void measure(
    ContentTableCell cell,
    MeasuredBlock block,
    double width,
    TextScaler scaler,
  ) {
    final character = cell.alignChar;
    if (character == null || block.lines.isEmpty) return;
    final line = block.lines.first;
    final text = block.text.substring(line.start, line.end);
    final index = text.indexOf(character);
    final painter = block.createSingleLinePainter(
      lineIndex: 0,
      textScaler: scaler,
    );
    final prefix = index < 0
        ? painter.width
        : painter.getOffsetForCaret(TextPosition(offset: index), Rect.zero).dx;
    painter.dispose();
    _prefix[block] = prefix;
    final raw = cell.charOffset?.trim();
    final offset = raw == null
        ? 0.0
        : raw.endsWith('%')
        ? (double.tryParse(raw.substring(0, raw.length - 1)) ?? 0) * width / 100
        : double.tryParse(raw) ?? 0;
    _stops[cell.column] = math.max(
      _stops[cell.column] ?? 0,
      math.max(prefix, offset.isFinite ? offset : 0),
    );
  }

  double inset(ContentTableCell cell, MeasuredBlock block, double width) {
    final prefix = _prefix[block];
    if (prefix == null) return 0;
    return ((_stops[cell.column] ?? 0) - prefix).clamp(
      0.0,
      math.max(0.0, width - block.lines.first.width),
    );
  }
}
