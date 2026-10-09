/// 阅读排版设置（设计文档 9.3）。
///
/// 这里保存阅读排版参数，以及全局字体的应用范围：字号、行高、段距、页边距、首行缩进、字体，
/// 以及排版模式（简化 / 原书）。
/// 阅读主题只是换颜色，不进分页缓存键，换主题不重排（设计文档 6.4）。
library;

/// 排版模式（设计文档 2.4「排版模式」）。
///
/// - [simplified]：简化排版，Flutter 自研分页（默认）；
/// - [original]：原书排版，WebView 按原书 CSS 渲染（EPUB 专属，见
///   `docs/原书排版模式实现计划.md`）。
///
/// 只有 EPUB 能选原书排版；TXT 没有原书样式，界面不出现这个开关。
enum ReadingLayoutMode {
  simplified('simplified'),
  original('original');

  const ReadingLayoutMode(this.code);

  final String code;

  /// 解码：值不认识时回退简化排版（单项越界只回退该项，设计文档 7.2）
  static ReadingLayoutMode fromCode(Object? code) => values.firstWhere(
        (mode) => mode.code == code,
        orElse: () => ReadingLayoutMode.simplified,
      );

  /// 是否用 WebView 渲染原书样式
  bool get isOriginal => this == ReadingLayoutMode.original;
}

/// 点按和拖动共用的翻页方式；独立于分页与排版模式。
enum PageTurnEffect {
  none('无动画'), slide('平移翻页'), cover('覆盖翻页'), curl('仿真翻页'), scroll('滚动');
  const PageTurnEffect(this.label);
  final String label;
  static PageTurnEffect fromCode(Object? code) => values.firstWhere(
    (value) => value.name == code, orElse: () => PageTurnEffect.curl);
}

/// 参数取值范围与默认值（设计文档 9.3 Token 表）。
abstract final class ReadingLimits {
  static const int minFontSize = 14;
  static const int maxFontSize = 44;
  static const double minLineHeight = 1.2;
  static const double maxLineHeight = 2.2;
  static const double minParagraphGapEm = 0;
  static const double maxParagraphGapEm = 1.5;
  static const double minHorizontalPadding = 16;
  static const double maxHorizontalPadding = 40;

  static const int defaultFontSize = 17;
  static const double defaultLineHeight = 1.7;
  static const double defaultParagraphGapEm = 0.6;
  static const double defaultHorizontalPadding = 24;

  /// 正文上下留白（不含安全区与底部信息行）
  static const double verticalPadding = 24;
}

/// 内置默认阅读设置（设计文档 9.3 Token 表）。
///
/// 简化排版默认使用系统字体；原书排版默认保留原书字体。
/// 库里存了全局默认值或单书覆盖时，以库里那份为准。
const ReadingSettings kBuiltinReadingSettings =
    ReadingSettings(fontFamily: 'sans-serif');

class ReadingSettings {
  const ReadingSettings({
    this.fontSize = ReadingLimits.defaultFontSize,
    this.lineHeight = ReadingLimits.defaultLineHeight,
    this.paragraphGapEm = ReadingLimits.defaultParagraphGapEm,
    this.horizontalPadding = ReadingLimits.defaultHorizontalPadding,
    this.indent = true,
    this.fontFamily,
    this.fontOnlyInReader = true,
    this.bold = false,
    this.useOriginalFont = true,
    this.layoutMode = ReadingLayoutMode.simplified,
    this.pageTurnEffect = PageTurnEffect.curl,
    this.autoScrollSpeed = 24,
    this.autoScanSeconds = 8,
    this.autoKeepAwake = true,
  });

  /// 正文字号 14–44
  final int fontSize;

  /// 行高倍数 1.2–2.2
  final double lineHeight;

  /// 段后间距，相对字号（em）
  final double paragraphGapEm;

  /// 正文左右页边距
  final double horizontalPadding;

  /// 普通正文首行缩进 2em
  final bool indent;

  /// 字体标识；null 表示系统默认字体。
  /// 后续打包字体时换成「字体文件名 + 哈希」，进缓存键。
  final String? fontFamily;

  /// 全局字体的应用范围；单书覆盖不能改变应用界面的字体。
  final bool fontOnlyInReader;

  /// 加粗正文；原书字体默认保留，选字体后才覆盖。
  final bool bold;
  final bool useOriginalFont;

  /// 排版模式（简化 / 原书）；原书模式只对 EPUB 生效
  final ReadingLayoutMode layoutMode;
  final PageTurnEffect pageTurnEffect;
  /// 滚动速度用逻辑像素/秒；扫描耗时单独保存，互不换算。
  final double autoScrollSpeed;
  final int autoScanSeconds;
  final bool autoKeepAwake;

  /// 段后间距的像素值
  double get paragraphGap => paragraphGapEm * fontSize;

  ReadingSettings copyWith({
    int? fontSize,
    double? lineHeight,
    double? paragraphGapEm,
    double? horizontalPadding,
    bool? indent,
    String? fontFamily,
    bool? fontOnlyInReader,
    bool? bold,
    bool? useOriginalFont,
    bool clearFontFamily = false,
    ReadingLayoutMode? layoutMode,
    PageTurnEffect? pageTurnEffect,
    double? autoScrollSpeed,
    int? autoScanSeconds,
    bool? autoKeepAwake,
  }) =>
      ReadingSettings(
        fontSize: (fontSize ?? this.fontSize)
            .clamp(ReadingLimits.minFontSize, ReadingLimits.maxFontSize),
        lineHeight: (lineHeight ?? this.lineHeight)
            .clamp(ReadingLimits.minLineHeight, ReadingLimits.maxLineHeight),
        paragraphGapEm: (paragraphGapEm ?? this.paragraphGapEm).clamp(
          ReadingLimits.minParagraphGapEm,
          ReadingLimits.maxParagraphGapEm,
        ),
        horizontalPadding: (horizontalPadding ?? this.horizontalPadding).clamp(
          ReadingLimits.minHorizontalPadding,
          ReadingLimits.maxHorizontalPadding,
        ),
        indent: indent ?? this.indent,
        bold: bold ?? this.bold,
        useOriginalFont: useOriginalFont ?? this.useOriginalFont,
        fontOnlyInReader: fontOnlyInReader ?? this.fontOnlyInReader,
        fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
        layoutMode: layoutMode ?? this.layoutMode,
        pageTurnEffect: pageTurnEffect ?? this.pageTurnEffect,
        autoScrollSpeed: (autoScrollSpeed ?? this.autoScrollSpeed).clamp(12, 80),
        autoScanSeconds: (autoScanSeconds ?? this.autoScanSeconds).clamp(2, 30),
        autoKeepAwake: autoKeepAwake ?? this.autoKeepAwake,
      );

  /// 「单书覆盖 > 全局设置 > 内置默认」的字段级合并（设计文档 2.3）。
  ///
  /// [overrides] 里为 null 的项表示未覆盖，沿用下层值。
  ReadingSettings mergeOver(ReadingSettingsOverrides overrides) => ReadingSettings(
        fontSize: overrides.fontSize ?? fontSize,
        lineHeight: overrides.lineHeight ?? lineHeight,
        paragraphGapEm: overrides.paragraphGapEm ?? paragraphGapEm,
        horizontalPadding: overrides.horizontalPadding ?? horizontalPadding,
        indent: overrides.indent ?? indent,
        bold: overrides.bold ?? bold,
        useOriginalFont: overrides.useOriginalFont ?? useOriginalFont,
        fontFamily: overrides.fontFamily ?? fontFamily,
        fontOnlyInReader: fontOnlyInReader,
        layoutMode: overrides.layoutMode ?? layoutMode,
        pageTurnEffect: overrides.pageTurnEffect ?? pageTurnEffect,
        autoScrollSpeed: overrides.autoScrollSpeed ?? autoScrollSpeed,
        autoScanSeconds: overrides.autoScanSeconds ?? autoScanSeconds,
        autoKeepAwake: overrides.autoKeepAwake ?? autoKeepAwake,
      );

  Map<String, Object?> toJson() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'paragraphGapEm': paragraphGapEm,
        'horizontalPadding': horizontalPadding,
        'indent': indent,
        'bold': bold,
        'useOriginalFont': useOriginalFont,
        'fontOnlyInReader': fontOnlyInReader,
        if (fontFamily != null) 'fontFamily': fontFamily,
        // 老数据没有这一项：读出来就是默认的简化排版（加键不迁移 schema）
        'layoutMode': layoutMode.code,
        'pageTurnEffect': pageTurnEffect.name,
        'autoScrollSpeed': autoScrollSpeed,
        'autoScanSeconds': autoScanSeconds,
        'autoKeepAwake': autoKeepAwake,
      };

  /// 解码设置：单项越界或类型不对只回退该项，不影响其它项
  /// （设计文档 7.2 实现约定）。
  static ReadingSettings fromJson(Map<String, Object?> json) {
    const base = ReadingSettings();
    final size = (json['fontSize'] as num?)?.toInt();
    final line = (json['lineHeight'] as num?)?.toDouble();
    final gap = (json['paragraphGapEm'] as num?)?.toDouble();
    final padding = (json['horizontalPadding'] as num?)?.toDouble();
    final indent = json['indent'];
    final family = json['fontFamily'];
    return ReadingSettings(
      fontSize: size == null
          ? base.fontSize
          : size.clamp(ReadingLimits.minFontSize, ReadingLimits.maxFontSize),
      lineHeight: line == null
          ? base.lineHeight
          : line.clamp(
              ReadingLimits.minLineHeight,
              ReadingLimits.maxLineHeight,
            ),
      paragraphGapEm: gap == null
          ? base.paragraphGapEm
          : gap.clamp(
              ReadingLimits.minParagraphGapEm,
              ReadingLimits.maxParagraphGapEm,
            ),
      horizontalPadding: padding == null
          ? base.horizontalPadding
          : padding.clamp(
              ReadingLimits.minHorizontalPadding,
              ReadingLimits.maxHorizontalPadding,
            ),
      indent: indent is bool ? indent : base.indent,
      bold: json['bold'] is bool ? json['bold'] as bool : false,
      useOriginalFont: json['useOriginalFont'] is bool
          ? json['useOriginalFont'] as bool : true,
      fontOnlyInReader: json['fontOnlyInReader'] as bool? ?? true,
      fontFamily: family is String && family.isNotEmpty ? family : null,
      layoutMode: ReadingLayoutMode.fromCode(json['layoutMode']),
      pageTurnEffect: PageTurnEffect.fromCode(json['pageTurnEffect']),
      autoScrollSpeed: (json['autoScrollSpeed'] as num?)?.toDouble().clamp(12, 80) ?? 24,
      autoScanSeconds: (json['autoScanSeconds'] as num?)?.toInt().clamp(2, 30) ?? 8,
      autoKeepAwake: json['autoKeepAwake'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReadingSettings &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.paragraphGapEm == paragraphGapEm &&
      other.horizontalPadding == horizontalPadding &&
      other.indent == indent &&
      other.bold == bold &&
      other.useOriginalFont == useOriginalFont &&
      other.fontFamily == fontFamily &&
      other.fontOnlyInReader == fontOnlyInReader &&
      other.layoutMode == layoutMode && other.pageTurnEffect == pageTurnEffect &&
      other.autoScrollSpeed == autoScrollSpeed && other.autoScanSeconds == autoScanSeconds &&
      other.autoKeepAwake == autoKeepAwake;

  @override
  int get hashCode => Object.hash(
        fontSize,
        lineHeight,
        paragraphGapEm,
        horizontalPadding,
        indent,
        bold,
        useOriginalFont,
        fontFamily,
        fontOnlyInReader,
        layoutMode,
        pageTurnEffect,
        autoScrollSpeed, autoScanSeconds, autoKeepAwake,
      );
}

/// 单书覆盖项：字段为 null 表示这一项沿用全局值。
class ReadingSettingsOverrides {
  const ReadingSettingsOverrides({
    this.fontSize,
    this.lineHeight,
    this.paragraphGapEm,
    this.horizontalPadding,
    this.indent,
    this.fontFamily,
    this.bold,
    this.useOriginalFont,
    this.layoutMode,
    this.pageTurnEffect,
    this.autoScrollSpeed,
    this.autoScanSeconds,
    this.autoKeepAwake,
  });

  final int? fontSize;
  final double? lineHeight;
  final double? paragraphGapEm;
  final double? horizontalPadding;
  final bool? indent;
  final String? fontFamily;
  final bool? bold;
  final bool? useOriginalFont;

  /// 排版模式覆盖；null 表示跟随全局默认
  final ReadingLayoutMode? layoutMode;
  final PageTurnEffect? pageTurnEffect;
  final double? autoScrollSpeed;
  final int? autoScanSeconds;
  final bool? autoKeepAwake;

  /// 只改传入的那几项，其余保持原样（面板每次只调一个参数）
  ReadingSettingsOverrides copyWith({
    int? fontSize,
    double? lineHeight,
    double? paragraphGapEm,
    double? horizontalPadding,
    bool? indent,
    String? fontFamily,
    bool? bold,
    bool? useOriginalFont,
    bool clearFontFamily = false,
    ReadingLayoutMode? layoutMode,
    PageTurnEffect? pageTurnEffect,
    double? autoScrollSpeed,
    int? autoScanSeconds,
    bool? autoKeepAwake,
  }) =>
      ReadingSettingsOverrides(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        paragraphGapEm: paragraphGapEm ?? this.paragraphGapEm,
        horizontalPadding: horizontalPadding ?? this.horizontalPadding,
        indent: indent ?? this.indent,
        bold: bold ?? this.bold,
        useOriginalFont: useOriginalFont ?? this.useOriginalFont,
        fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
        layoutMode: layoutMode ?? this.layoutMode,
        pageTurnEffect: pageTurnEffect ?? this.pageTurnEffect,
        autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
        autoScanSeconds: autoScanSeconds ?? this.autoScanSeconds,
        autoKeepAwake: autoKeepAwake ?? this.autoKeepAwake,
      );

  Map<String, Object?> toJson() => {
        if (fontSize != null) 'fontSize': fontSize,
        if (lineHeight != null) 'lineHeight': lineHeight,
        if (paragraphGapEm != null) 'paragraphGapEm': paragraphGapEm,
        if (horizontalPadding != null) 'horizontalPadding': horizontalPadding,
        if (indent != null) 'indent': indent,
        if (bold != null) 'bold': bold,
        if (useOriginalFont != null) 'useOriginalFont': useOriginalFont,
        if (fontFamily != null) 'fontFamily': fontFamily,
        if (layoutMode != null) 'layoutMode': layoutMode!.code,
        if (pageTurnEffect != null) 'pageTurnEffect': pageTurnEffect!.name,
        if (autoScrollSpeed != null) 'autoScrollSpeed': autoScrollSpeed,
        if (autoScanSeconds != null) 'autoScanSeconds': autoScanSeconds,
        if (autoKeepAwake != null) 'autoKeepAwake': autoKeepAwake,
      };

  static ReadingSettingsOverrides fromJson(Map<String, Object?> json) =>
      ReadingSettingsOverrides(
        fontSize: (json['fontSize'] as num?)?.toInt(),
        lineHeight: (json['lineHeight'] as num?)?.toDouble(),
        paragraphGapEm: (json['paragraphGapEm'] as num?)?.toDouble(),
        horizontalPadding: (json['horizontalPadding'] as num?)?.toDouble(),
        indent: json['indent'] is bool ? json['indent'] as bool : null,
        bold: json['bold'] is bool ? json['bold'] as bool : null,
        useOriginalFont: json['useOriginalFont'] is bool
            ? json['useOriginalFont'] as bool : null,
        fontFamily:
            json['fontFamily'] is String ? json['fontFamily'] as String : null,
        // 键不存在时是 null（未覆盖），不能用 fromCode 的默认值兜底
        pageTurnEffect: json.containsKey('pageTurnEffect')
            ? PageTurnEffect.fromCode(json['pageTurnEffect']) : null,
        autoScrollSpeed: (json['autoScrollSpeed'] as num?)?.toDouble().clamp(12, 80),
        autoScanSeconds: (json['autoScanSeconds'] as num?)?.toInt().clamp(2, 30),
        autoKeepAwake: json['autoKeepAwake'] as bool?,
        layoutMode: json.containsKey('layoutMode')
            ? ReadingLayoutMode.fromCode(json['layoutMode'])
            : null,
      );

  bool get isEmpty =>
      fontSize == null &&
      lineHeight == null &&
      paragraphGapEm == null &&
      horizontalPadding == null &&
      indent == null &&
      bold == null &&
      useOriginalFont == null &&
      fontFamily == null &&
      layoutMode == null && pageTurnEffect == null && autoScrollSpeed == null &&
      autoScanSeconds == null && autoKeepAwake == null;

  /// 把当前设置整体变成一份覆盖（「恢复全局」是删除覆盖，不是写全局快照）。
  static ReadingSettingsOverrides of(ReadingSettings settings) =>
      ReadingSettingsOverrides(
        fontSize: settings.fontSize,
        lineHeight: settings.lineHeight,
        paragraphGapEm: settings.paragraphGapEm,
        horizontalPadding: settings.horizontalPadding,
        indent: settings.indent,
        bold: settings.bold,
        useOriginalFont: settings.useOriginalFont,
        fontFamily: settings.fontFamily,
        layoutMode: settings.layoutMode,
        pageTurnEffect: settings.pageTurnEffect,
        autoScrollSpeed: settings.autoScrollSpeed,
        autoScanSeconds: settings.autoScanSeconds,
        autoKeepAwake: settings.autoKeepAwake,
      );
}

/// 全局阅读偏好（设计文档 2.3 的「全局阅读默认值」层）。
///
/// 启动时由 `bootstrap` 读一次注入，让阅读页第一帧就是用户上次的主题与排版，
/// 不会先按内置默认值画一遍再切（AGENTS 规则 8）。
class GlobalReadingPreferences {
  const GlobalReadingPreferences({
    this.typography = kBuiltinReadingSettings,
    this.themeId,
  });

  /// 库里没有任何设置时使用（内置默认值）
  static const defaults = GlobalReadingPreferences();

  final ReadingSettings typography;

  /// 阅读主题标识（`ReadingTheme.name`）；null 表示用内置默认主题
  final String? themeId;

  @override
  bool operator ==(Object other) =>
      other is GlobalReadingPreferences &&
      other.typography == typography &&
      other.themeId == themeId;

  @override
  int get hashCode => Object.hash(typography, themeId);
}
