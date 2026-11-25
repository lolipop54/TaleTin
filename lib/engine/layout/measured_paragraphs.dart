import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';

import 'measured_text_geometry.dart';

typedef _Paragraph = ({double width, int units, TextPainter painter});

/// 把刚排好的整段交给分页或滚动的首次绘制。绘制接手后负责释放 TextPainter。
class MeasuredParagraphs {
  MeasuredParagraphs(this._foreground);

  final Color? Function(bool caption) _foreground;
  final _pending = Map<List<MeasuredLine>, _Paragraph>.identity();
  static const _maxUnits = 32768;
  @visibleForTesting
  int get debugReuseCount => _debugReuseCount;
  int _debugReuseCount = 0;

  int _units = 0;
  bool _closed = false;

  Color? foreground(bool caption) => _closed ? null : _foreground(caption);

  void keep(
    List<MeasuredLine> lines,
    double width,
    int length,
    TextPainter painter,
  ) {
    if (_closed || length > _maxUnits) {
      painter.dispose();
      return;
    }
    final previous = _pending.remove(lines);
    if (previous != null) {
      _units -= previous.units;
      previous.painter.dispose();
    }
    _pending[lines] = (width: width, units: length, painter: painter);
    _units += length;
    while (_pending.length > 192 || _units > _maxUnits) {
      final oldest = _pending.remove(_pending.keys.first)!;
      _units -= oldest.units;
      oldest.painter.dispose();
    }
  }

  TextPainter? take(
    List<MeasuredLine> lines,
    double width,
    TextScaler scaler,
    TextSpan span,
  ) {
    final entry = _pending.remove(lines);
    if (entry == null) return null;
    _units -= entry.units;
    final painter = entry.painter;
    // 行表属于本次测量。再核对最终字色、书内字体、缩放和宽度，
    // 夜间对比度或阅读设置切换后，仍由实际绘制的样式决定。
    if (entry.width == width &&
        painter.textScaler == scaler &&
        painter.text == span) {
      assert(() {
        _debugReuseCount++;
        return true;
      }());
      return painter;
    }
    painter.dispose();
    return null;
  }

  void dispose() {
    _closed = true;
    for (final entry in _pending.values) {
      entry.painter.dispose();
    }
    _pending.clear();
    _units = 0;
  }
}
