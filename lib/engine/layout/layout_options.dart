/// 排版参数：既是渲染依据，也是分页缓存键的来源（实现计划 4 / 5.8）。
///
/// 测量与绘制必须用这里给出的同一份 [TextStyle]、同一个内容宽度和**同一个
/// TextScaler 实例**：Android 14+ 的系统字号缩放是非线性的，折算成单一系数会
/// 让布局行数与渲染行数不一致，页尾出现整行空白（设计文档 6.4）。
library;

import 'dart:io';

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/reading_settings.dart';
import '../../core/diagnostics/reader_delivery_experiments.dart';
import '../styles/tag_defaults.dart';
import '../styles/style_box_value.dart'
    show TextDecorationSpec, TextDecorationLine, TextDecorationLineStyle;
import 'publication_font_set.dart';

typedef PreparePublicationFonts = Future<LayoutOptions> Function(
  String,
  ChapterContent,
  LayoutOptions,
);

/// 读 `TagDefaults` 里的相对字号（`0.9em` → 0.9），供图注、代码块共用。
double _tagFontFactor(String tag) {
  final raw = TagDefaults.table[tag]?['font-size'];
  if (raw == null) return 1;
  final match = RegExp(r'^([0-9.]+)em$').firstMatch(raw.trim());
  return match == null ? 1 : (double.tryParse(match.group(1)!) ?? 1);
}

/// 标题相对正文的固定像素增量，按 h1～h6 排列。
///
/// 产品规则（2026-10-31 用户确认）：标题字号 = 正文字号 + 固定像素差，不按整页
/// 字号等比缩放。手机正文字号从 14 调到 28 时，如果标题按 1.5 倍走，h2 会从
/// 21px 涨到 42px，页面只剩几行；固定差让大字号下的标题仍然只是「比正文大一点」。
///
/// 只在这里定义一次：标签默认表里不写 h1～h6 的 `font-size`，否则将来做 CSS
/// 层叠时会把这里的差值和表里的倍数乘在一起。书里显式写的相对字号（行内
/// `style` 或作者样式表）仍按原来的规则乘在这个结果上。
const List<double> _headingSizeDelta = [6, 4, 3, 2, 1, 1];

/// 标题相对正文的像素增量：h1～h6，超出范围按 h6，未给级别按 h1（章题）。
double headingSizeDelta(int? level) =>
    _headingSizeDelta[(level ?? 1).clamp(1, 6) - 1];

/// 标题行高倍数：标题不跟随正文字号的行高，2.2 倍行高放在标题上太散
const double _headingLineHeight = 1.35;

/// 脚注字号相对正文的减小量
const double _footnoteSizeDelta = 2;

/// 代码块行高倍数（代码要紧凑一些）
const double _codeLineHeight = 1.45;

/// 代码块使用的等宽字体族（Android 与桌面都能解析到系统等宽字体）
const String kCodeFontFamily = 'monospace';

/// 上下标相对正文的字号比例与垂直偏移（em）
const double kScriptScale = 0.72;
const double kSuperscriptShift = 0.3;
const double kSubscriptShift = 0.18;

/// 引用块左右缩进（em）：与标签默认表里 `blockquote` 的 `margin` 一致。
///
/// 数值从 `TagDefaults.quoteIndent` 解析，两处不再各写一份（测试会核对）。
double get _quoteIndentEm => _tagEm(TagDefaults.quoteIndent, fallback: 2);

/// 列表项每级缩进（em）：与标签默认表里 `ul`／`ol` 的 `padding-left` 一致。
double get _listIndentEm => _tagEm(TagDefaults.listIndent, fallback: 1.6);

/// 列表每加深一级增加的缩进（引擎默认，CSS 没有对应属性）。
const double _listIndentStepEm = 1.4;

/// 把 `2em`、`1.6em` 这类标签默认值解析成数字；解析不了时用兜底值。
double _tagEm(String raw, {required double fallback}) {
  final match = RegExp(r'^([0-9.]+)em$').firstMatch(raw.trim());
  return match == null
      ? fallback
      : (double.tryParse(match.group(1)!) ?? fallback);
}

class LayoutOptions {
  const LayoutOptions({
    required this.settings,
    required this.contentSize,
    required this.textScaler,
    this.paperInset = Offset.zero,
    this.paperBottomInset,
    this.insertChapterTitle = false,
    this.spreadDocumentChapters = false,
    this.cssDark = false,
    this.pageInk,
    this.publicationFonts = PublicationFontSet.empty,
  });

  // 只给首次绘字复用，不参与断行、分页或磁盘缓存身份。
  final ({Color primary, Color secondary})? pageInk;
  final ReadingSettings settings;
  final PublicationFontSet publicationFonts;

  LayoutOptions withPublicationFonts(PublicationFontSet fonts) => LayoutOptions(
    settings: settings,
    contentSize: contentSize,
    paperInset: paperInset,
    paperBottomInset: paperBottomInset,
    textScaler: textScaler,
    insertChapterTitle: insertChapterTitle,
    spreadDocumentChapters: spreadDocumentChapters,
    cssDark: cssDark,
    pageInk: pageInk,
    publicationFonts: fonts,
  );

  // 章内字体身份只用于该章的缓存，视口签名仍需能跨章节比较。
  String get chapterSignature => publicationFonts.identity.isEmpty
      ? layoutSignature
      : '$layoutSignature|${publicationFonts.identity}';

  /// 只用于 prefers-color-scheme；实际阅读主题在 UI 层决定。
  final bool cssDark;

  /// 是否在章首补「章题 + 下方一条短横线」。
  ///
  /// 只有 TXT 打开：TXT 的章名被切去当目录，正文里没有标题，不补就看不到章名。
  /// EPUB／MOBI／AZW3 和 PDF 电子书都按原书内容与样式排，不额外加标题或横线。
  final bool insertChapterTitle;
  final bool spreadDocumentChapters;

  /// 正文可用区域（已扣除页边距、顶部信息行、底部状态行与安全区）
  final Size contentSize;

  /// 正文原点距当前这一页纸左边、上边的距离。连续滚动只使用横向留白。
  final Offset paperInset;

  /// 上、下信息栏可独立隐藏。未提供下边距时纸面按上下对称处理。
  final double? paperBottomInset;

  /// 与界面渲染使用的同一个实例（来自 `MediaQuery.textScalerOf`）
  final TextScaler textScaler;

  /// 引擎版本：分页规则变化时递增，让旧缓存自动失效。
  ///
  /// 4：引用块、代码块、列表层级、块级对齐与硬换行参与测量和分页。
  /// 5：书内样式表（颜色、背景、边框、内边距、字号）参与测量和分页。
  /// 6：边框逐边解析、盒子包住图片、引用层级缩进规则修正。
  /// 7：有书内盒子时不再叠加默认引用缩进；列表跟随外层盒子；代码行重排宽度。
  /// 8：盒子位置按外层容器计算，列表项的列表缩进不再推动盒子。
  /// 9：下划线／删除线、small 字号、列表标记类型、图片显式宽度。
  /// 10：缓存盒子带阴影个数（修复恢复后虚线变实线）；深色底不再被提亮。
  /// 11：缓存保留书内文字颜色（修复恢复后红底白字变黑字）。
  /// 12：分隔线继承盒子并按书里的线型绘制。
  /// 13：段落中间的行内图片按实际尺寸参与断行，比行高大时增高该行。
  /// 14：块与片段的样式改从章节样式表按 `styleId` 取。
  /// 15：标题字号改回「正文 + 固定像素差」，分页高度随之变化。
  /// 16：只有 TXT 补章题和短横线，其他格式遵原书；分页高度随之变化。
  /// 17：片段样式改从章节样式表按 `styleId` 取（颜色、下划线、上下标、相对字号），
  ///     表格在引用框里按盒子内边距量宽；旧测量结果不能复用。
  /// 18：首行缩进不再被下划线覆盖；引用块自身诗行不缩进；深层引用只缩进一层；
  ///     表格单元格不再叠加引用缩进；`<br>` 在样式边界处也能正常换行。
  /// 19：同上，补一次缓存隔离，避免中间调试版本留下的旧正文／排版结果继续命中。
  /// 20：中间调试包生成过 content19 正文（没有 qb），再隔离一次。
  /// 21：测量断点也要按新的 qb/缩进规则失效，避免恢复旧前缀缩进。
  /// 22：表格按原书 `<col>` 百分比列宽排版，不再一律平均分栏。
  /// 23：表格基准字号按原书 0.88em，窄列不再挤爆。
  /// 24：表格字号 0.82em，并给百分比列一个最小宽度，模拟原书自动布局。
  /// 25：表格字号再收到 0.78em，避免窄列把 Value 这类短词也多拆一行。
  /// 26：三列表格的首列最小宽度提到 18%，Value 不再拆行。
  /// 27：首列最小宽度再提到 20%，Query 也不再拆行。
  /// 28：首列最小宽度提到 22%，「（查询）」也放得下。
  /// 29：引用框包住代码框；普通段落对齐／缩进与原书覆盖规则一致。
  /// 30：恢复书内居中／右对齐段落，不给它们补首行缩进。
  /// 36：列表不再叠加书内 padding 与阅读器固定缩进；只写一边的边框取到颜色；
  ///     行内 `<code>` 的背景／内边距重新参与测量；强制分页边界落在换行符上时
  ///     不再多算空行，MOBI 书名不再被图片盖住。
  /// 37：块级／行内判断收成一处（display_role），行内 `<code>` 在显示树里
  ///     也按行内处理，不再和行内盒子得到两个答案。
  /// 38：盒子四边各存各的颜色；断点格式同步升级到 measured-prefix-10。
  /// 39：缩进来源按「自己的盒子 → 列表祖先的 padding → 阅读器兜底」统一；
  ///     只设背景的列表也会补一档，图片与文字共用同一份判断。
  /// 40：换行符、强制断行、行内图片都作为断行事件处理，行首不会出现换行符，
  ///     同一位置只断一次，行高总和与块高一致。
  /// 41：`<hr>` 不再被空元素装饰重复量一次（少一条线、少一份外边距）；
  ///     书里显式写的标题相对字号按正文乘，不再叠加固定差值；
  ///     原图宽于正文的百分比插图铺满正文，与原书排版一致。
  /// 42：分隔线块改记在 `<hr>` 自己名下，容器链完整；容器跨多块时
  ///     底部边框按最后一片判断，不再漏画盒子底边。
  /// 43：统一容器约束和块内显示范围；深层缩进保留可读宽度，框的上下
  ///     位置与跨页范围进入断点；显式 1em 与未设置字号分开。
  /// 44：MathML 备用注释不显示、图片独占行居中、页面纵向定位与插图分页修正。
  /// 45：首行缩进不参与字距拉伸；数学运算符使用统一数学字体和数学轴。
  /// 46：固定缩进行保留真实字形起点；随包符号字体匹配原书箭头比例和高度。
  /// 47：公式 SVG、基线和完整原文范围参与分页与滚动。
  /// 48：分段混排的首字放不进余宽时整段换行，不沿用旧的溢出分页。
  /// 49：数字连字符参与普通及分段正文断行，不复用旧的整串移行结果。
  /// 50：两字首行缩进按字号固定为2em，不受字体全角空格字宽影响。
  /// 51：祖先容器宽度逐层生效；独立图片遵守书内百分比，不因原图像素大而铺满。
  /// 52：背景图进入容器测量和断点，恢复后保留资源及铺图参数。
  /// 53：标题宽度、四角圆角、元素盒子归属与文字样式统一用于分页和滚动。
  /// 54：保留 body 相对字号的累计倍率；hr 只绘制一条分隔线。
  /// 55：来源标签参与深层引用/列表边距适配，首层作者边距不再叠兜底缩进。
  /// 56：hr 按浏览器默认样式和完整边框盒测量、绘制。
  /// 57：正文 p 不再叠上外边距；旧式 HTML 字号参与测量。
  /// 59：含图片段落两端对齐、图片后来源br及圆角边框转弯。
  /// 60：hr currentColor 使用浏览器的特殊凹边绘色，作废旧测量和颜色。
  /// 61：源码换行和空白、透明阴影、逐边边框及跨页表格装饰。
  /// 62：源码行首空白跨标签累计，作废中间验证包的旧缩进测量。
  /// 63：引用空段首边、框内列表标记、表格对齐和跨页延长。
  /// 64：测量样式身份及缓存保留字距、词距与片段阴影。
  /// 65：纯链接段落缩进与表格内部块级起止边界。
  /// 66：旧式HTML对齐、来源br、小字基线及并排图文的测量与分页。
  /// 67：列表内段落、空白兄弟br及长点线断行；旧式p按正文对齐。
  /// 68：普通正文字号基准、隐藏章题、中文标点断行、扉页定位及p标题。
  /// 69：裸三角及箭头使用单色字形，行内装饰按自身字体和基线计算高度。
  /// 70：独立公式保留原来的行高和基线，作废中间测试包的测量结果。
  /// 71：拼音注音、图片高度与注释，以及浮动图文测量。
  /// 72：浮动图文继续保留块的边框和背景，旧测量会在读章时更新。
  /// 73：标题等正文块自己的边框只量一次，旧的行内装饰和分页重新计算。
  /// 74：简化排版隐藏书内 display:none 的正文块。
  /// 75：简化排版使用书内表格单元格的尺寸和边框。
  /// 76：隐藏行内元素及表格行，保留正文位置。
  /// 77：相对容器叠图、首字绕排、并排行内盒和空浮动装饰进入测量。
  /// 80：绝对定位插图、书内留白，以及容器外边距和目录分组间距。
  /// 81：EPUB 局部小字、图片尺寸、盒子外边距和封面叠图。
  /// 82：相邻单图叠放时一起调整位置，保留负外边距算出的距离。
  /// 89：按包含块和 box-sizing 换算作者的尺寸，旧测量与分页缓存重新生成。
  /// 90：表格按列声明、跨格范围及内容断点计算最终列宽。
  /// 91：按单元格内容、跨行和首行基线决定行高。
  /// 92：表题占位、空格外观及表格各来源合并边线的几何。
  /// 93：长表换页后逐格保留行高和原文字位。
  /// 94：缓存行组避断位置，跨行格的边线随各行实际断点绘制。
  /// 95：根背景图独占的章节也生成一页，旧版可能把它识别为空章。
  /// 96：分页缓存包含续页表头占用的高度，阅读位置继续使用原文。
  /// 98：按剩余正文宽度决定是否逐层使用引用边距，旧分页从原文位置重新生成。
  /// 99：缓存图片缩放、横纵圆角和注音原书字色，重新按原文字位定位。
  /// 101：派生分页重新计算；独立保存的滚动位置用实际图文几何及原文复核。
  /// 102：有边框的列表按实际序号宽度留白，旧分页从原文字位重新排。
  /// 103：浮动头像、跨容器的并排诗句和连续画廊图注按新的位置重新分页。
  /// 104：图注与原图同页，文字负边距按实际字框避让。
  /// 105：人物介绍跨页、章首插画纸边和题花外边距。
  /// 106：段首显式换行、列表序号列、相邻图注和独立封面重新测量。
  /// 108：旧 HTML、MOBI 缩进与分页、表格背景和双向文字按新几何重排。
  /// 109：按可见 br 的个数恢复空行，旧页从原来的正文字位重新排。
  /// 110：边框首尾角标按原书行高重排。
  /// 111：分页按当前纸面的剩余高度排标题、插图和图注。
  /// 112：普通插图与左右浮图按页尾余量最多缩小四成，浮图旁的文字重新断行。
  /// 113：浮图的长说明可在完整图名和首行之后续页。
  /// 114：分页按每一行的绕图宽度判断图注和旁栏正文的续行位置。
  /// 115：居中定宽扉页在窄屏内排版，正文和表格保留相邻不换行词组的边界。
  /// 116：表内代码按栏宽续行，表格居中和靠右使用最终列宽。
  /// 117：定宽章题在窄栏内重排，文字与边框共用适配后的宽度。
  /// 118：超宽表格按所在栏重新分配列宽，满版章题在正文区内断行。
  /// 119：标题内的块级题花独占一行；显式贴边的章首横图可后接章号。
  static const int engineVersion = 119;

  double get contentWidth => contentSize.width;

  double get listMarkerGap => settings.fontSize * .35;

  double get contentHeight => contentSize.height;

  /// 段后间距像素值
  double get paragraphGap => settings.paragraphGap;

  /// 首行缩进前缀。
  ///
  /// 保留两个占位字符参与坐标换算；测量与绘制统一用2em空白替代，
  /// 避免字体把全角空格画成半角或零宽。缩进仍计入首行换行宽度。
  String get indentPrefix => '\u3000\u3000';

  /// 块内容宽度：引用块左右各缩进两字，列表项按层级左侧缩进。
  ///
  /// [nest] 对引用块及其内部的任何块都表示「引用层级」（从 1 开始），
  /// 这样引用框里的图片、图注、标题也会跟着一起缩进，盒子不会错位。
  double contentWidthFor(BlockKind kind, {int nest = 0}) =>
      contentWidth -
      insetFor(kind, nest: nest) -
      rightInsetFor(kind, nest: nest);

  /// 列表项左侧缩进：第一级要放得下「1.」这样的标记。
  ///
  /// 与原书排版一致：第二层起的嵌套列表不再继续增加缩进，否则多层列表会把
  /// 文本挤到页面右侧（有些书用 8 层 `blockquote` 当排版缩进，逐层相加会
  /// 偏出大半页）。第一级与第二级各占一档，之后保持同一缩进。
  double listIndentFor({int nest = 0}) =>
      settings.fontSize.toDouble() *
      (_listIndentEm + (nest > 0 ? 1 : 0) * _listIndentStepEm);

  /// 列表项／引用块的左侧绘制偏移
  ///
  /// 旧正文缺少来源容器时仅补一层缩进。有容器时引用宽度由 DisplayBoxLayout 计算。
  double insetFor(BlockKind kind, {int nest = 0}) {
    final em = settings.fontSize.toDouble();
    return switch (kind) {
      BlockKind.listItem => listIndentFor(nest: nest),
      // 引用块自身固定只缩进一层；嵌套层级再深也不再累加。
      BlockKind.quote => em * _quoteIndentEm,
      _ => nest > 0 ? em * _quoteIndentEm : 0,
    };
  }

  /// 右侧缩进：引用块与原书一致，右边也收两字
  double rightInsetFor(BlockKind kind, {int nest = 0}) {
    if (kind == BlockKind.quote || nest > 0) {
      return settings.fontSize.toDouble() * _quoteIndentEm;
    }
    return 0;
  }

  /// 文本样式工厂：测量与绘制**只能**通过它取样式。
  ///
  /// [script]：0 正常、1 上标、2 下标（只缩小字号，位移在绘制时处理）。
  TextStyle textStyleFor(
    BlockKind kind, {
    int? level,
    bool bold = false,
    bool italic = false,
    bool hasFontWeight = false,
    int script = 0,
    Color? color,
    double sizeScale = 1,
    bool hasFontSize = false,
    List<Shadow>? shadows,
    bool underline = false,
    bool strike = false,
    TextDecorationSpec? bookDecoration,

    /// 字距／词距（相对字号：0.05 表示 0.05em）；null 表示书里没写。
    double? letterSpacing,
    double? wordSpacing,
  }) {
    final base = settings.fontSize.toDouble();
    final family = settings.fontFamily;
    final weight = FontWeight.values[settings.fontWeight ~/ 100 - 1];
    final explicitScale = hasFontSize || sizeScale != 1;
    final style = switch (kind) {
      BlockKind.heading => TextStyle(
        // 书里没写标题字号时，标题 = 正文 + 固定像素差（见 [_headingSizeDelta]）。
        // 书里写了相对字号（h1 常见 2em、h2 常见 1.5em）时，按正文字号乘，
        // 和原书 WebView 的结果一致；不能先加差值再乘，否则 2em 会变成
        // (正文 + 6) × 2，同一本书的标题比原书排版大一圈。
        fontSize: explicitScale
            ? (base * sizeScale).clamp(8.0, double.infinity)
            : base + headingSizeDelta(level),
        fontWeight: hasFontWeight
            ? (bold && settings.fontWeight < 600 ? FontWeight.w600 : weight)
            : settings.fontWeight == 700
            ? FontWeight.w700
            : FontWeight.w600,
        height: _headingLineHeight,
        fontFamily: family,
      ),
      BlockKind.footnote => TextStyle(
        fontSize: base - _footnoteSizeDelta,
        fontWeight: weight,
        height: settings.lineHeight,
        fontFamily: family,
      ),
      BlockKind.caption => TextStyle(
        // 图注按标签默认 igcaption 的相对字号（0.9em），不再用固定像素差。
        fontSize: base * _tagFontFactor('figcaption'),
        fontWeight: weight,
        height: settings.lineHeight,
        fontFamily: family,
      ),
      BlockKind.codeBlock => TextStyle(
        // 代码块按标签默认 pre 的相对字号（0.9em）。
        fontSize: base * _tagFontFactor('pre'),
        fontWeight: weight,
        height: _codeLineHeight,
        fontFamily: kCodeFontFamily,
      ),
      _ => TextStyle(
        fontSize: base,
        height: settings.lineHeight,
        fontWeight: bold && settings.fontWeight < 600
            ? FontWeight.w600
            : weight,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        fontFamily: family,
      ),
    };
    var result = style;
    // 粗体、斜体也适用于代码和图注，不能只在普通正文分支生效。
    if (bold && settings.fontWeight < 600) {
      result = result.copyWith(fontWeight: FontWeight.w600);
    }
    if (italic) result = result.copyWith(fontStyle: FontStyle.italic);
    // 字距／词距按字号换算成像素：书里写的是相对值（0.05em），换字号时同比缩放。
    if (letterSpacing != null && letterSpacing != 0) {
      result = result.copyWith(letterSpacing: letterSpacing * result.fontSize!);
    }
    if (wordSpacing != null && wordSpacing != 0) {
      result = result.copyWith(wordSpacing: wordSpacing * result.fontSize!);
    }
    // 标题已经在上面的分支里乘过书里的相对字号，不能再乘一次；
    // 其他块（正文、图注、代码）仍在这里统一乘。
    if (sizeScale != 1 && kind != BlockKind.heading) {
      result = result.copyWith(
        fontSize: (result.fontSize! * sizeScale).clamp(8.0, double.infinity),
      );
    }
    if (script != 0) {
      result = result.copyWith(
        fontSize: result.fontSize! * kScriptScale,
        fontStyle: italic ? FontStyle.italic : result.fontStyle,
      );
    }
    if (color != null) result = result.copyWith(color: color);
    if (shadows != null && shadows.isNotEmpty) {
      result = result.copyWith(shadows: shadows);
    }
    final overline =
        bookDecoration?.lines.contains(TextDecorationLine.overline) ?? false;
    if (underline || strike || overline) {
      final ink = bookDecoration?.color?.argb;
      result = result.copyWith(
        decorationColor: ink == null ? null : Color(ink),
        decorationStyle: switch (bookDecoration?.style) {
          TextDecorationLineStyle.double => TextDecorationStyle.double,
          TextDecorationLineStyle.dotted => TextDecorationStyle.dotted,
          TextDecorationLineStyle.dashed => TextDecorationStyle.dashed,
          TextDecorationLineStyle.wavy => TextDecorationStyle.wavy,
          TextDecorationLineStyle.solid => TextDecorationStyle.solid,
          null => null,
        },
        decoration: TextDecoration.combine([
          if (overline) TextDecoration.overline,
          if (underline) TextDecoration.underline,
          if (strike) TextDecoration.lineThrough,
        ]),
      );
    }
    return result;
  }

  /// 块后是否需要两端对齐：代码、图注和明确居中／右对齐的块不拉伸。
  bool justifies(BlockKind kind, String? align) {
    if (align == 'center' || align == 'right' || align == 'left') return false;
    return switch (kind) {
      BlockKind.paragraph ||
      BlockKind.listItem ||
      BlockKind.quote ||
      BlockKind.heading ||
      BlockKind.footnote => true,
      _ => false,
    };
  }

  /// 块前是否补段距：标题与其后紧跟的块之间用段距的一半做呼吸，正文块之间用整段距。
  double? gapBefore(BlockKind previous, BlockKind current) {
    if (previous == BlockKind.heading) return paragraphGap * 0.5;
    // 图注紧贴它上面的图片，不额外撑开
    if (current == BlockKind.caption) return paragraphGap * 0.5;
    return paragraphGap;
  }

  /// 分页缓存键：内容版本、章节、字体、字号/行高/段距/缩进/页边距、内容区尺寸、
  /// TextScaler 与引擎版本全部在内；颜色主题不在键内（换主题不重排）。
  String get layoutSignature => [
    'v$engineVersion',
    readingGeometrySignature,
    // 旧版 Windows 量的是纯文字回退，不能沿用其分页、滚动断点或页数。
    if (Platform.isWindows) 'mathSvg1',
    if (settings.spreadEnabled && spreadDocumentChapters) 'spreadOpening1',
  ].join('|');

  /// 原文进度可以跨引擎升级保存；只用真正影响版面的阅读设置来核对视口。
  String get readingGeometrySignature {
    final scaler = textScaler;
    // 采样几个字号点：既能区分线性倍数，也能区分非线性缩放曲线
    final exact = ReaderDeliveryExperiments.incremental;
    final scalerKey =
        (exact
                ? [
                    for (var size = 1; size <= settings.fontSize + 8; size++)
                      scaler.scale(size.toDouble()).toString(),
                  ]
                : [
                    scaler.scale(10).toStringAsFixed(2),
                    scaler.scale(20).toStringAsFixed(2),
                    scaler.scale(40).toStringAsFixed(2),
                  ])
            .join(',');
    return [
      'cssDark$cssDark',
      if (paperInset != Offset.zero) 'paper${paperInset.dx},${paperInset.dy}',
      if (paperBottomInset != null) 'bottom$paperBottomInset',
      'f${settings.fontFamily ?? 'system'}',
      's${settings.fontSize}',
      'weight${settings.fontWeight}|originalFont${settings.useOriginalFont}',
      if (settings.useBookFontsInSimplified) 'bookFonts1',
      'l${settings.lineHeight}',
      'g${settings.paragraphGapEm}',
      'p${settings.horizontalPadding}',
      'i${settings.indent ? 1 : 0}',
      'ct${insertChapterTitle ? 1 : 0}',
      if (settings.spreadEnabled)
        spreadDocumentChapters
            ? 'spreadChapters2-true'
            : 'spreadChapters1-false',
      'w${exact ? contentSize.width : contentSize.width.toStringAsFixed(1)}',
      'h${exact ? contentSize.height : contentSize.height.toStringAsFixed(1)}',
      'ts$scalerKey',
    ].join('|');
  }

  /// 该块能否被拆到两页（图片、分隔线不可拆）
  static bool isSplittable(BlockKind kind) => switch (kind) {
    BlockKind.image || BlockKind.divider => false,
    _ => true,
  };
}
