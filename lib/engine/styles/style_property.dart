/// 一个属性在引擎里的完整定义：类型、继承、初始值、落到哪里、现在做到哪一步。
///
/// 这个文件只放「定义」本身；82 个属性的具体内容按 ID 段拆在
/// `style_properties_text.dart`／`_box.dart`／`_block.dart`／`_size.dart` 里，
/// 由 `style_registry.dart` 汇总并提供查询。
library;

/// 属性值的类型；解析器按这个类型选对应的解析函数。
enum StyleValueType {
  length,
  size,
  color,
  fontSize,
  lineHeight,
  fontWeight,
  fontStyle,
  textAlign,
  textTransform,
  whiteSpace,
  display,
  verticalAlign,
  decoration,
  shadow,
  borderWidth,
  borderStyle,
  borderColor,
  corners,
  background,
  listStyle,
  number,
  keyword,
  string,
}

/// 属性作用在哪一类对象上。一个属性可以同时作用于多类（例如 `width`）。
enum TargetKind { text, block, inlineBox, replaced, table, tableCell }

/// 属性最终落到哪个几何原语上。
enum StylePrimitive {
  textStyle,
  edges,
  decoration,
  atomicInline,
  lineBox,
  tableCell,
  verticalGap,
  listMarker,
}

/// 谁消费这个属性。
enum StyleConsumer {
  inlineFlow,
  blockFlow,
  replacedFlow,
  tableFlow,
  painter,
  verticalGap,
}

enum StyleStatus {
  parsed,
  mapped,
  rendered,
  verified,
  ignoredByDesign,
  blockedByLayout,
  blockedByProductDecision,
  blockedByEnvironment,
  blockedByMediaQuery,
}

// 常用作用对象集合：表里逐行写 `{TargetKind.text}` 太长，也容易漏写花括号。
const Set<TargetKind> kTextTargets = {TargetKind.text};
const Set<TargetKind> kBlockTargets = {TargetKind.block};
const Set<TargetKind> kBoxTargets = {TargetKind.block, TargetKind.inlineBox};
const Set<TargetKind> kSizeTargets = {TargetKind.block, TargetKind.replaced};
const Set<TargetKind> kReplacedTargets = {TargetKind.replaced};
const Set<TargetKind> kTableTargets = {TargetKind.table};
const Set<TargetKind> kTableCellTargets = {TargetKind.tableCell};

class StyleProperty {
  const StyleProperty({
    required this.id,
    required this.cssName,
    required this.valueType,
    required this.inherited,
    required this.initial,
    required this.appliesTo,
    required this.affectsGeometry,
    required this.primitive,
    required this.consumer,
    required this.status,
    required this.phase,
    this.notes = '',
  });

  /// 稳定整数 ID；写进缓存和 Rust 常量表，不能随便改。
  final int id;

  /// CSS 属性名（长写；简写见 `StyleRegistry.shorthands`）。
  final String cssName;

  final StyleValueType valueType;

  /// 是否继承。继承由样式解析器统一处理，不靠手工传参。
  final bool inherited;

  /// CSS 初始值的原始写法；null 表示「由阅读器基准（第 1 层）提供」。
  ///
  /// 例如 `color` 的 CSS 初始值是系统色 `CanvasText`，我们的初始值是主题文字色，
  /// 所以这里写 null，由阅读器给值，不假装有一个 CSS 初始值。
  final String? initial;

  final Set<TargetKind> appliesTo;

  /// 是否影响几何：为 true 时，值变化必须让测量/分页缓存失效；
  /// 只影响颜色的属性为 false，改主题只需要重画。
  final bool affectsGeometry;

  final StylePrimitive primitive;
  final StyleConsumer consumer;
  final StyleStatus status;

  /// 计划在哪个批次实现，便于回答「为什么这个属性还没生效」。
  final String phase;

  final String notes;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': cssName,
    'type': valueType.name,
    'inherited': inherited,
    'initial': initial,
    'appliesTo': [for (final kind in appliesTo) kind.name]..sort(),
    'affectsGeometry': affectsGeometry,
    'primitive': primitive.name,
    'consumer': consumer.name,
    'status': status.name,
    'phase': phase,
    'notes': notes,
  };
}
