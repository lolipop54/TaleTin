import 'measured_block.dart';

/// 一个阅读会话持有的小量块测量。键包含只读正文对象与完整测量参数。
/// 取消的整章排版也可留下已完成的块，不保存进行中的结果或分页状态。
class BlockMeasurementCache {
  BlockMeasurementCache({this.capacity = 512, this.maxTextUnits = 200000});
  final int capacity, maxTextUnits;
  final _entries = <Object, MeasuredBlock>{};
  int _textUnits = 0;

  MeasuredBlock? get(Object key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(Object key, MeasuredBlock value) {
    final previous = _entries.remove(key);
    _textUnits -= previous?.text.length ?? 0;
    if (value.text.length > maxTextUnits) return;
    _entries[key] = value;
    _textUnits += value.text.length;
    while (_entries.length > capacity || _textUnits > maxTextUnits) {
      _textUnits -= _entries.remove(_entries.keys.first)!.text.length;
    }
  }

  void clear() {
    _entries.clear();
    _textUnits = 0;
  }
}
