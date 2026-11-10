/// 每章一张去重的样式表：块和文字片段只带整数 `styleId`，不再各自背一堆显示字段。
///
/// 为什么去重要按「语义」而不是「像素」：`margin-top: 1em` 和 `margin-top: 16px`
/// 在 16px 基准下像素相同，但用户一改字号就不同了；按像素去重会把它们错误合并。
/// 这里的去重键就是计算样式的规范 JSON，单位原样保留。
///
/// 表里有两份摘要，用途不同：
/// - [fullDigest]：所有记录（含颜色、背景），进正文缓存身份——样式变了要重新读正文；
/// - [geometryDigest]：只含会影响测量/分页的字段（见 `style_geometry.dart`），
///   进测量断点身份——只改颜色不必重排。
///
/// ID 约定：0 固定是「默认样式」（空样式），块/片段没有样式时统一写 0；
/// 其它 ID 按首次出现顺序分配，同一章内稳定；跨章不共享（章表随正文缓存一起存）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'computed_style.dart';
import 'computed_style_json.dart';
import 'style_geometry.dart';

/// 样式表格式版本。键名或字段语义变化时递增；旧缓存遇到不同版本按「无法解析」处理。
const int styleSchemaVersion = 1;

/// 默认样式的 ID：没有任何作者样式时用它。
const int kDefaultStyleId = 0;

class StyleTable {
  StyleTable._(this._records, this._index);

  /// 空表：只含默认样式。
  factory StyleTable() =>
      StyleTable._([ComputedStyle.empty], {_keyOf(ComputedStyle.empty): 0});

  /// 从一批样式构造（测试与迁移期使用）。
  factory StyleTable.of(Iterable<ComputedStyle> styles) {
    final table = StyleTable();
    for (final style in styles) {
      table.intern(style);
    }
    return table;
  }

  final List<ComputedStyle> _records;

  /// 语义键 → ID；键是规范 JSON，不包含 `extras`（它只用于诊断，不进缓存）。
  final Map<String, int> _index;

  int get length => _records.length;

  /// 登记一份计算样式，返回它的 ID；语义相同的样式复用同一个 ID。
  int intern(ComputedStyle style) {
    if (style.isEmpty) return kDefaultStyleId;
    final key = _keyOf(style);
    final existing = _index[key];
    if (existing != null) return existing;
    final id = _records.length;
    _records.add(style);
    _index[key] = id;
    return id;
  }

  /// 按 ID 取样式；越界或未知 ID 一律退回默认样式，不抛异常——
  /// 样式表是缓存，损坏时应当降级成「没有作者样式」，不能因此打不开书。
  ComputedStyle operator [](int id) =>
      id >= 0 && id < _records.length ? _records[id] : ComputedStyle.empty;

  /// 全部记录（按 ID 顺序，只读）。
  List<ComputedStyle> get records => List.unmodifiable(_records);

  Map<String, Object?> toJson() => {
    'v': styleSchemaVersion,
    'styles': [for (final style in _records) computedStyleToJson(style)],
  };

  /// 解析样式表；版本不符或结构损坏返回 null（调用方按「没有作者样式」降级）。
  static StyleTable? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['v'] != styleSchemaVersion) return null;
    final raw = json['styles'];
    if (raw is! List || raw.isEmpty) return null;
    // 第 0 条必须是默认样式：块/片段引用 0 时才能安全地退回「没有样式」。
    if (!computedStyleFromJson(raw.first).isEmpty) return null;
    final table = StyleTable();
    for (final item in raw.skip(1)) {
      table.intern(computedStyleFromJson(item));
    }
    return table;
  }

  /// 完整样式摘要（SHA-256 十六进制）。含颜色、背景、阴影等所有字段。
  String get fullDigest => _digest(computedStyleToJson);

  /// 几何样式摘要：按**正文里块/片段的顺序**取每个样式的几何投影再哈希。
  ///
  /// 为什么必须按顺序、而不是按表里的记录顺序：
  /// - 只改颜色会新增一条「只有颜色」的记录，表内记录数和顺序都会变，
  ///   但几何一个像素都没变；按块顺序投影时它投影成空，摘要不变；
  /// - 两个块互换样式时，表里记录可能还是那几条，但块的引用顺序变了，
  ///   必须让摘要跟着变，否则会复用错误的分页。
  ///
  /// [ids] 由调用方按正文顺序给出（块 ID 与它内部片段的 ID 交替或并列均可，
  /// 只要每次调用用同一种顺序）。
  String geometryDigestFor(Iterable<int> ids) => sha256
      .convert(
        utf8.encode(
          jsonEncode([for (final id in ids) geometryStyleJson(this[id])]),
        ),
      )
      .toString();

  String _digest(Map<String, Object?> Function(ComputedStyle) project) => sha256
      .convert(utf8.encode(jsonEncode([for (final s in _records) project(s)])))
      .toString();

  static String _keyOf(ComputedStyle style) =>
      jsonEncode(computedStyleToJson(style));
}
