/// 属性注册表：引擎认识哪些 CSS 属性、每个属性落到哪里、现在做到哪一步。
///
/// 这张表的用处不是「给程序员看的文档」，而是**加属性时唯一的入口**：
/// - 解析器从这里知道该产出什么类型的值；
/// - 排版上下文从这里知道该属性归谁消费；
/// - 覆盖报告和测试从这里知道「哪些属性只解析了、还没生效」；
/// - Rust 侧的常量表由 `tool/style_tables_gen.dart` 从这张表生成，
///   两边不会各写一份再慢慢漂移。
///
/// 状态含义（和《简化排版引擎架构定义与重构实施计划261029》7.2 一致）：
/// - `parsed`：能读出值，排版不消费，用户看不到效果；
/// - `mapped`：值进了 `ComputedStyle`，但还没画；
/// - `rendered`：画面真的生效了；
/// - `verified`：有合成样例 + 真实书页 + 对照，可以写进「已支持」；
/// - `ignoredByDesign`：明确不做，原因写在 [StyleProperty.notes]；
/// - `blockedByLayout`：要做就得先有新的排版上下文（浮动、定位、flex）；
/// - `blockedByProductDecision`：技术上能做，但会改变正文/位置口径，等产品规则；
/// - `blockedByEnvironment`：依赖设备宽度/主题，离线解析时不知道；
/// - `blockedByMediaQuery`：写在 `@media` 里，本次只记录不应用。
///
/// 属性条目按 ID 段拆在四个文件里（文字 1xxx、盒子 2xxx、块级 3xxx、尺寸与表格 4xxx／5xxx），
/// 这里只负责汇总和查询；加属性时先找对文件，再加一行。
library;

import 'style_properties_block.dart';
import 'style_properties_box.dart';
import 'style_properties_size.dart';
import 'style_properties_text.dart';
import 'style_property.dart';

// 使用方（测试、覆盖报告、生成器）只需要 import 这个文件，
// 所以把属性定义相关的类型一起转出去。
export 'style_property.dart';

abstract final class StyleRegistry {
  /// 注册表自身的版本；属性增删或语义变化时递增，进缓存身份。
  static const int version = 3;

  /// 全部属性。顺序 = 文字 → 盒子 → 块级 → 尺寸/表格，Rust 常量表按同样顺序生成。
  static final List<StyleProperty> properties = [
    ...kTextProperties,
    ...kBoxProperties,
    ...kBlockProperties,
    ...kSizeProperties,
  ];

  /// 简写 → 它展开成哪些长写属性。
  ///
  /// 覆盖报告按简写统计声明次数，但状态按长写算；解析器展开简写后再查长写。
  static const Map<String, List<String>> shorthands = {
    'border-radius': [
      'border-top-left-radius',
      'border-top-right-radius',
      'border-bottom-right-radius',
      'border-bottom-left-radius',
    ],
    'margin': ['margin-top', 'margin-right', 'margin-bottom', 'margin-left'],
    'padding': [
      'padding-top',
      'padding-right',
      'padding-bottom',
      'padding-left',
    ],
    'border-width': [
      'border-top-width',
      'border-right-width',
      'border-bottom-width',
      'border-left-width',
    ],
    'border-style': [
      'border-top-style',
      'border-right-style',
      'border-bottom-style',
      'border-left-style',
    ],
    'border-color': [
      'border-top-color',
      'border-right-color',
      'border-bottom-color',
      'border-left-color',
    ],
    'border': [
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
    ],
    'border-top': ['border-top-width', 'border-top-style', 'border-top-color'],
    'border-right': [
      'border-right-width',
      'border-right-style',
      'border-right-color',
    ],
    'border-bottom': [
      'border-bottom-width',
      'border-bottom-style',
      'border-bottom-color',
    ],
    'border-left': [
      'border-left-width',
      'border-left-style',
      'border-left-color',
    ],
    'background': [
      'background-color',
      'background-image',
      'background-repeat',
      'background-position',
      'background-size',
    ],
    'font': [
      'font-style',
      'font-weight',
      'font-size',
      'line-height',
      'font-family',
    ],
    'list-style': ['list-style-type'],
    'text-decoration': ['text-decoration'],
    'overflow': ['overflow'],
  };

  /// 不属于 CSS 标准、但样书里真的在用的私有属性，以及它们等价的属性名。
  static const Map<String, String> aliases = {
    'duokan-text-indent': 'text-indent',
    'duokan-text-align': 'text-align',
    '-webkit-text-indent': 'text-indent',
    '-webkit-text-size-adjust': 'text-size-adjust',
    '-ms-text-size-adjust': 'text-size-adjust',
    '-webkit-user-select': 'user-select',
    '-moz-user-select': 'user-select',
    '-ms-user-select': 'user-select',
    '-khtml-user-select': 'user-select',
    'word-wrap': 'overflow-wrap',
    // 单方向溢出：我们目前只有一个 overflow 消费方，先按同一个属性记录。
    'overflow-x': 'overflow',
    'overflow-y': 'overflow',
    // CSS 2.1 的翻页属性是 CSS 3 同名属性的旧写法。
    'page-break-before': 'break-before',
    'page-break-after': 'break-after',
    'page-break-inside': 'break-inside',
  };

  static final Map<String, StyleProperty> _byName = {
    for (final property in properties) property.cssName: property,
  };

  static final Map<int, StyleProperty> _byId = {
    for (final property in properties) property.id: property,
  };

  static StyleProperty? byName(String cssName) => _byName[cssName];

  /// 别名先转成标准名再查。
  static StyleProperty? resolve(String cssName) {
    final canonical = aliases[cssName] ?? cssName;
    return _byName[canonical];
  }

  static StyleProperty? byId(int id) => _byId[id];

  /// 缺省值：显式登记过的属性按 CSS 初始值；没登记的按「不产生值」处理。
  static String? initialOf(String cssName) => resolve(cssName)?.initial;

  /// 导出给 Rust 生成器与覆盖报告；键名保持稳定。
  static Map<String, Object?> exportJson() => {
    'v': version,
    'properties': [for (final property in properties) property.toJson()],
    'shorthands': {
      for (final entry in shorthands.entries) entry.key: entry.value,
    },
    'aliases': aliases,
  };
}
