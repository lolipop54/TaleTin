/// 鍗曞潡鐨勬祴閲忕粨鏋滐細鍒嗛〉鍙仛绠楁湳锛屼笉鍐嶇 TextPainter锛堝疄鐜拌鍒?4 / 5.6锛夈€?
///
/// 鍏抽敭涓嶅彉閲忥細鎶?[lines] 鎸夐『搴忓彇鏂囨湰鎷艰捣鏉ワ紝绛変簬 [text]銆?
/// 鍒嗛〉鍒囧垎鍙寜琛岃竟鐣岃蛋锛屽洜姝ゃ€屾暣绔犳墍鏈夐〉鎷艰捣鏉?== 鏍囧噯鍖栨鏂囥€嶆槸缁撴瀯鎬ф垚绔嬬殑锛?
/// 涓嶄緷璧栦换浣曚簨鍚庡洖濉€?
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'edge_aligned_text_painter.dart';
import 'fixed_indent.dart';
import 'layout_options.dart';
import 'inline_box_placement.dart';
import 'measured_text_geometry.dart';
export 'measured_text_geometry.dart';
export 'inline_box_placement.dart';

import '../../domain/models/book_document.dart';

part 'script_text_geometry.dart';

class MeasuredBlock {
  const MeasuredBlock({
    required this.blockId,
    required this.kind,
    this.level,
    this.text = '',
    this.runs = const [],
    this.runStyles = const [],
    this.lines = const [],
    this.height = 0,
    this.pageTop,
    this.imageSize,
    this.resourcePath,
    this.alt,
    this.inset = 0,
    this.isDecoration = false,
    this.decorationAtStart = false,
    this.displayPrefixLength = 0,
    this.isTitleDecoration = false,
    this.tableId,
    this.tableBounds,
    this.tableTop = 0,
    this.tableUnit = 0,
    this.tableHeader = false,
    this.tableBox,
    this.isTableBox = false,
    this.layoutWidth,
    this.align,
    this.marker,
    this.markerInset = 0,
    this.justify = false,
    this.hasScript = false,
    this.box,
    this.boxId,
    this.containerBoxes = const [],
    this.codeBox,
    this.codeTop = 0,
    this.codeBottom = 0,
    this.line,
    this.boxIndent = 0,
    this.bodyTop = 0,
    this.bodyBottom = 0,
    this.boxFirst = true,
    this.boxLast = true,
    this.marginTop = 0,
    this.marginBottom = 0,
    this.textStyle = const BlockTextStyle(),
    this.inlineImages = const [],
    this.inlineBoxes = const [],
  });

  final String blockId;
  final String? tableId;

  /// 二维图文流复用分组位置与断点字段，但没有表格边线或单元格缩放。
  bool get isParallelFlow => tableId?.startsWith('__parallel_') == true;
  final Rect? tableBounds;
  final double tableTop, tableUnit;
  final bool tableHeader;

  /// 表格外层容器（引用块）的盒子；单元格自己的 [box] 仍为空。
  ///
  /// 分页时每个表格组只生成一个盒子片段，把表格画进和前后段落相同的引用框；
  /// 表格单元格不逐个套框，否则一页上会出现很多截断的小方框。
  final BlockBox? tableBox;

  /// 只用于画表格外层盒子的合成块，不是正文内容，不能成为页首／页尾位置。
  final bool isTableBox;
  final double? layoutWidth;

  /// 鍧楃骇瀵归綈锛歚center`锛廯right`锛沶ull 琛ㄧず宸﹀榻愩€?
  final String? align;

  /// 鍒楄〃鏍囪鏂囧瓧锛坄1.`銆乣鈥 绛夛級锛岀敾鍦ㄦ鏂囧乏渚э紝涓嶈繘鍏ユ枃鏈祦銆?
  final String? marker;

  /// 鏍囪鍙宠竟缂樼浉瀵瑰潡宸﹀唴杈硅窛鐨勪綅缃?
  final double markerInset;

  /// 鏄惁涓ょ瀵归綈锛堜唬鐮併€佸浘娉ㄣ€佸眳涓紡鍙冲榻愮殑鍧椾负 false锛?
  final bool justify;

  /// 鏄惁鍚笂鏍囷紡涓嬫爣鐗囨锛堢粯鍒舵椂瑕侀噸鐢诲苟涓婁笅鍋忕Щ锛?
  final bool hasScript;

  /// 鍒嗛殧绾胯嚜宸辩殑绾垮瀷 `[瀹藉害(px), 绾垮瀷, 棰滆壊]`锛沶ull 鐢ㄩ粯璁ょ煭绾?
  final List<int>? line;

  /// 涔﹀唴鏍峰紡琛ㄧ粰鐨勭洅瀛愶紙鑳屾櫙銆佽竟妗嗐€佸渾瑙掋€侀槾褰便€佸唴杈硅窛锛?
  final BlockBox? box;

  /// 同一涓洅瀛愬鍣ㄩ噷鐨勮繛缁潡鍏辩敤杩欎釜缂栧彿
  final int? boxId;

  /// 显示树里的外层容器（外层→内层，不含块自己的 [box]）。
  /// 绘制时先画外层背景、再画内层；跨页只用首尾标志决定上下边框。
  final List<ContainerBoxFrame> containerBoxes;

  /// 引用框里的代码框；外层继续使用 box/boxId 连接前后段落。
  final BlockBox? codeBox;

  /// 内层代码框自己的内边距与外边距，不能随外层容器的中间块一起删掉。
  final double codeTop, codeBottom;

  /// 鐩掑瓙鍐呭鍖轰粠鍧楀乏杈圭紭寰€鍙冲缂╄繘鐨勯儴鍒嗭紙鍒楄〃椤硅嚜宸辩殑鍒楄〃缂╄繘锛夈€?
  ///
  /// 鐩掑瓙鏈韩鏄灞傚鍣ㄧ敾鐨勶紝涓嶈兘璺熺潃鍒楄〃椤圭殑缂╄繘涓€璧峰彸绉伙紝鍚﹀垯缈诲埌鍒楄〃椤垫椂
  /// 鏁翠釜寮曠敤妗嗕細鏁翠綋閿欎綅锛涚敾鐩掑瓙鏃舵妸瀹冩墸鎺夈€?
  final double boxIndent;

  /// 鍧楅《閮紡搴曢儴涓嶅睘浜庤鐩掔殑楂樺害锛堝唴杈硅窛 + 杈规锛夈€?
  ///
  /// 鍒嗛〉鏃跺彧鏈夊潡鐨勭涓€鐗囧甫 [bodyTop]銆佹渶鍚庝竴鐗囧甫 [bodyBottom]锛?
  /// 璺ㄩ〉鐨勪腑闂寸墖娈靛彧鏈夎楂樸€?
  final double bodyTop;
  final double bodyBottom;

  /// 作者样式给的上、下外边距（像素，已按字号换算）。阅读器段距是另一份设置，
  /// 块间距 = max(段距, 上一块的下外边距, 这一块的上外边距)，不会相加。
  final double marginTop;
  final double marginBottom;

  /// 鍚屼竴涓洅瀛愬鍣ㄩ噷鐨勭涓€鍧楋紡鏈€鍚庝竴鍧楋細鍙湁瀹冧滑鐢讳笂涓嬭竟妗嗐€佸渾瑙掑拰涓婁笅鍐呰竟璺濄€?
  final bool boxFirst;
  final bool boxLast;

  /// 涔﹀唴鎸囧畾鐨勬枃瀛楅鑹蹭笌闃村奖
  final BlockTextStyle textStyle;

  /// 娈佃惤涓棿鐨勮鍐呭浘鐗囷紙浣嶇疆銆佸昂瀵搞€佹墍鍦ㄨ锛夛紱涓虹┖琛ㄧず鏅€氭枃瀛楀潡銆?
  final List<InlineImagePlacement> inlineImages;
  final List<InlineBoxPlacement> inlineBoxes;

  /// 鍥剧墖鎴栬鍐呭唴杈硅窛鎶婃枃瀛楀垎寮€鏃讹紝缁樺埗鍜屽懡涓叡鐢ㄦ祴閲忓嚭鐨勫垎娈靛潗鏍囥€?
  bool get hasSegmentedText =>
      hasInlineImages ||
      inlineBoxes.isNotEmpty ||
      lines.any((line) => line.segments.isNotEmpty);

  /// 杩欎竴鍧楁槸鍚︽湁琛屽唴鍥剧墖锛涚粯鍒朵笌鏂囧瓧鍛戒腑瑕佹寜鍒嗘浣嶇疆澶勭悊銆?
  bool get hasInlineImages => inlineImages.isNotEmpty;

  /// 鏈潡鍦?[from]锛堝惈锛夊埌 [to]锛堜笉鍚級琛屼箣闂寸殑琛屽唴鍥剧墖銆?
  Iterable<InlineImagePlacement> inlineImagesInLines(int from, int to) =>
      inlineImages.where((image) => image.line >= from && image.line < to);

  /// 鎸夈€岀洅瀛愰噷绗嚑鍧椼€嶈皟鏁翠笂涓嬪唴杈硅窛锛氫腑闂村潡涓嶅啀鍗犱笂涓嬪唴杈硅窛涓庤竟妗嗐€?
  MeasuredBlock asBoxPart({required bool first, required bool last}) {
    final top = first ? bodyTop : codeTop;
    final bottom = last ? bodyBottom : codeBottom;
    return withBoxEdges(
      first: first,
      last: last,
      bodyTop: top,
      bodyBottom: bottom,
      height: height - (bodyTop - top) - (bodyBottom - bottom),
    );
  }

  /// 鎸夊墠鍚庣浉閭诲潡鍐冲畾鑷繁鍦ㄧ洅瀛愰噷鐨勪綅缃紝骞跺仛涓婁笅鍐呰竟璺濊皟鏁淬€?
  ///
  /// 鐩掑瓙瀹瑰櫒鏄€岃繛缁潡鍏辩敤涓€涓?boxId銆嶏細绗竴鍧楃敾涓婅竟妗嗕笌涓婂唴杈硅窛锛屾渶鍚庝竴鍧楃敾涓嬭竟妗嗕笌
  /// 涓嬪唴杈硅窛锛屼腑闂村潡鍙繚鐣欏乏鍙抽儴鍒嗭紝杩欐牱鑳屾櫙鍜岃竟妗嗘墠鑳借繛鎴愪竴鏁村潡锛岃€屼笉鏄瘡娈甸兘濂椾竴鍦堛€?
  /// 杩欓噷鍙緷璧栧墠鍚庡潡鐨?boxId锛屼笉淇敼鍧楁湰韬互澶栫殑浠讳綍涓滆タ銆?
  MeasuredBlock fitBoxPart(MeasuredBlock? previous, MeasuredBlock? next) {
    final id = boxId;
    if (id == null || box == null) return this;
    final first = previous == null || previous.boxId != id;
    final last = next == null || next.boxId != id;
    if (boxFirst == first && boxLast == last) return this;
    return asBoxPart(first: first, last: last);
  }

  MeasuredBlock withBoxEdges({
    required bool first,
    required bool last,
    double? bodyTop,
    double? bodyBottom,
    double? height,
    double? pageTop,
  }) => MeasuredBlock(
    blockId: blockId,
    kind: kind,
    level: level,
    text: text,
    runs: runs,
    runStyles: runStyles,
    lines: lines,
    height: height ?? this.height,
    pageTop: pageTop ?? this.pageTop,
    imageSize: imageSize,
    resourcePath: resourcePath,
    alt: alt,
    inset: inset,
    isDecoration: isDecoration,
    decorationAtStart: decorationAtStart,
    displayPrefixLength: displayPrefixLength,
    isTitleDecoration: isTitleDecoration,
    tableId: tableId,
    tableBounds: tableBounds,
    tableTop: tableTop,
    tableUnit: tableUnit,
    tableHeader: tableHeader,
    tableBox: tableBox,
    isTableBox: isTableBox,
    layoutWidth: layoutWidth,
    align: align,
    marker: marker,
    markerInset: markerInset,
    justify: justify,
    hasScript: hasScript,
    line: line,
    box: box,
    boxId: boxId,
    containerBoxes: containerBoxes,
    codeBox: codeBox,
    codeTop: codeTop,
    codeBottom: codeBottom,
    boxIndent: boxIndent,
    bodyTop: bodyTop ?? this.bodyTop,
    bodyBottom: bodyBottom ?? this.bodyBottom,
    boxFirst: first,
    boxLast: last,
    marginTop: marginTop,
    marginBottom: marginBottom,
    textStyle: textStyle,
    inlineImages: inlineImages,
    inlineBoxes: inlineBoxes,
  );

  /// 杩欎竴椤电墖娈甸噷鏂囧瓧鐨勮捣濮嬬旱鍚戜綅缃紙鍧楃殑绗竴鐗囪璺宠繃椤堕儴鍐呰竟璺濅笌杈规锛夈€?
  double textTopOf(int lineFrom) => lineFrom == 0 ? bodyTop : 0;

  MeasuredBlock inTable({
    required String id,
    required Rect bounds,
    required double top,
    required double unit,
    required bool header,
    required double width,
    List<ContainerBoxFrame> containerBoxes = const [],
    double tableBottom = 0,
    BlockBox? tableBox,
    int? boxId,
    bool boxFirst = true,
    bool boxLast = true,
  }) => MeasuredBlock(
    blockId: blockId,
    kind: kind,
    level: level,
    text: text,
    runs: runs,
    runStyles: runStyles,
    lines: lines,
    height: height,
    imageSize: imageSize,
    resourcePath: resourcePath,
    alt: alt,
    inset: bounds.left + (id.startsWith('__parallel_') ? inset : 4),
    isDecoration: isDecoration,
    decorationAtStart: decorationAtStart,
    displayPrefixLength: displayPrefixLength,
    tableId: id,
    // 表格普通正文按阅读设置两端对齐；表头保留作者的居中/右对齐。
    align: header || kind != BlockKind.paragraph ? align : null,
    justify: header || kind != BlockKind.paragraph ? justify : true,
    hasScript: hasScript,
    tableBounds: bounds,
    tableTop: top,
    tableUnit: unit,
    tableHeader: header,
    tableBox: tableBox,
    layoutWidth: width,
    box: id.startsWith('__parallel_') ? box : null,
    // 只带盒子编号，不带盒子本身：前后段落和表格要算同一组，段距为 0，
    // 但盒子由分页时生成的那一个表格盒子片段来画。
    boxId: boxId,
    containerBoxes: containerBoxes,
    bodyTop: id.startsWith('__parallel_') ? bodyTop : 0,
    bodyBottom: id.startsWith('__parallel_') ? bodyBottom : tableBottom,
    boxFirst: boxFirst,
    boxLast: boxLast,
    textStyle: textStyle,
    inlineImages: inlineImages,
    inlineBoxes: inlineBoxes,
    marker: id.startsWith('__parallel_') ? marker : null,
    markerInset: id.startsWith('__parallel_') ? markerInset : 0,
    codeBox: id.startsWith('__parallel_') ? codeBox : null,
    codeTop: id.startsWith('__parallel_') ? codeTop : 0,
    codeBottom: id.startsWith('__parallel_') ? codeBottom : 0,
    line: id.startsWith('__parallel_') ? line : null,
    boxIndent: id.startsWith('__parallel_') ? boxIndent : 0,
    marginTop: id.startsWith('__parallel_') ? marginTop : 0,
    marginBottom: id.startsWith('__parallel_') ? marginBottom : 0,
  );
  final BlockKind kind;

  /// 鏍囬绾у埆锛? 琛ㄧず绔犻瑁呴グ鍧?
  final int? level;

  /// 鏁村潡鏂囨湰锛堟枃鏈潡鍚琛岀缉杩涘墠缂€锛?
  final String text;
  final List<TextRun> runs;

  /// 涓?[runs] 涓€涓€瀵瑰簲鐨勫畬鏁存牱寮忥紙鍚瓧鍙枫€佸瓧閲嶃€佽楂樸€佸瓧浣擄級
  final List<TextStyle> runStyles;

  final List<MeasuredLine> lines;

  /// 鏁村潡楂樺害锛堟枃鏈潡 = 鍚勮楂樺害涔嬪拰锛?
  final double height;

  /// 作者指定的页面纵向位置；分页与滚动共用，空间不足时顺延，避免遮盖正文。
  final double? pageTop;

  /// 鍥剧墖鍧楃殑鏄剧ず灏哄锛堝凡鎸夊唴瀹瑰搴︾瓑姣旂缉鏀撅級
  final Size? imageSize;
  final String? resourcePath;
  final String? alt;

  /// 鍒楄〃椤圭瓑鍧楃殑宸︿晶缁樺埗鍋忕Щ
  final double inset;

  /// 图片相对同一容器的内容区居中，分页与滚动使用同一个横坐标。
  double imageLeftIn(double availableWidth) => tableId != null
      ? inset
      : inset +
            math.max(
              0,
              ((layoutWidth ?? availableWidth) - (imageSize?.width ?? 0)) / 2,
            );

  /// 图片实际绘制区域，包含居中位置及容器上内边距；点按与绘制共用。
  Rect? imageRectIn(double availableWidth, {double top = 0}) =>
      imageSize == null
      ? null
      : Offset(imageLeftIn(availableWidth), top + bodyTop) & imageSize!;

  /// 棣栬缂╄繘鍓嶇紑鐨勫瓧绗︽暟锛? 鎴?2锛夈€?
  ///
  /// 缂╄繘鏄?*鐢诲嚭鏉ョ殑**涓や釜鍏ㄨ绌烘牸锛屼細杩涘叆 [text] 涓庤鍋忕Щ锛涜€?Locator 鐨勫亸绉?
  /// 浠ユ爣鍑嗗寲姝ｆ枃涓哄噯锛堜笉鍚缉杩涳級锛屼袱鑰呮崲绠楁椂蹇呴』鍑忔帀杩欎釜闀垮害锛屽惁鍒欐敼涓€娆?
  /// 缂╄繘璁剧疆灏变細璁╂墍鏈変綅缃暣浣撳亸绉讳袱涓瓧绗︺€?
  final int displayPrefixLength;

  /// 瑁呴グ鍧楋細鍙備笌鎺掔増涓庣粯鍒讹紝浣嗕笉灞炰簬姝ｆ枃鏂囨湰娴侊紙绔犻銆佸垎闅旂嚎锛?
  final bool isDecoration;

  /// 空容器位于首段之前；分页重放无需读取来源树也能决定是否补段距。
  final bool decorationAtStart;

  bool get isText => lines.isNotEmpty;

  /// 鎸夌珷棰樻牱寮忕粯鍒讹紙澶у瓧鍙?+ 涓嬫柟鐭垎闅旂嚎锛夈€?
  ///
  /// 绔犻閭ｄ釜鏍囬鏈変袱绉嶆潵婧愶細姝ｆ枃閲屾湰鏉ュ氨鏈夊悓鍚嶆爣棰樻椂鐩存帴鎶婂畠褰撶珷棰樼敤锛?
  /// 閬垮厤銆岀増鏉冧俊鎭€嶈繖绫绘爣棰橀噸澶嶅嚭鐜颁袱娆★紱姝ｆ枃娌℃湁鏍囬鏃舵墠琛ヤ竴涓楗板潡銆?
  final bool isTitleDecoration;

  /// 杩欎竴琛屾槸鍚﹁鎷夊紑瀛楄窛椤跺埌鍙宠竟銆?
  ///
  /// 纭崲琛岀粨鏉熺殑琛岋紙璇楁瓕銆佷唬鐮侊級鍜屾渶鍚庝竴琛屼笉鎷変几锛涘眳涓紡鍙冲榻愮殑鍧楁暣浣撲笉鎷変几銆?
  bool justifiesLine(int lineIndex) =>
      justify && !lines[lineIndex].hardBreak && lineIndex < lines.length - 1;

  /// 涓€琛屽湪鍧楀唴锛堜笉鍚?[inset]锛夌殑姘村钩璧风偣锛氬榻愬亸绉?+ 浠ｇ爜琛岀缉杩涖€?
  double horizontalOffset(int lineIndex, double maxWidth) {
    final line = lines[lineIndex];
    final available = maxWidth - line.left;
    final aligned = switch (align) {
      'center' => (available - line.width) / 2,
      'right' => available - line.width,
      _ => 0.0,
    };
    return line.left + (aligned > 0 ? aligned : 0);
  }

  /// 鏋勯€犵粯鍒舵煇娈佃鑼冨洿鐢ㄧ殑 [TextPainter]銆?
  ///
  /// **缁樺埗涓庢祴閲忓繀椤诲叡鐢ㄥ悓涓€濂楀弬鏁?*锛氬悓涓€涓?[TextScaler]锛堟潵鑷帓鐗堢殑
  /// `LayoutOptions`锛変笌鍚屼竴涓?[maxWidth]銆傚皯浼犳垨浼犻敊浠讳綍涓€涓紝鐢诲嚭鏉ョ殑琛屽氨
  /// 浼氬拰鎺掔増鏃剁畻鍑虹殑琛屼笉涓€鑷粹€斺€斿吀鍨嬬殑鐥囩姸鏄瘡琛屾湯灏剧暀鐧姐€侀〉灏鹃偅琛屾彁鍓嶇粨鏉?
  /// 锛堣璁℃枃妗?6.4锛夈€傝繖閲岀殑 `maxWidth` 搴斿綋鐩存帴鐢?`LayoutOptions.contentWidthFor`
  /// 鐨勮繑鍥炲€硷紝鑰屼笉鏄晫闈㈢洅瀛愮殑瀹藉害銆?
  ///
  /// [letterSpacing] 鐢ㄤ簬鎶婅灏剧┖妗ｆ憡鍒板瓧涓庡瓧涔嬮棿锛堣 [justifySpacingFor]锛夈€?
  /// 瀹冨彧褰卞搷缁樺埗锛屼笉鍙備笌娴嬮噺涓庢柇琛屻€?
  TextPainter createFragmentPainter({
    required int lineFrom,
    required int lineTo,
    required TextScaler textScaler,
    required double maxWidth,
    Color? color,
    double letterSpacing = 0,
    Color? scriptColor,
    Color Function(Color, Color?)? adaptColor,
  }) {
    // 鎷夊紑瀛楄窛鐨勮鐙珛缁樺埗锛屼笉鎶婅澶栧崐浠藉瓧璺濈畻杩涘彲鐢ㄥ搴︽垨鍐嶆鎶樿銆?
    if (letterSpacing > 0 && lineTo == lineFrom + 1) {
      return createSingleLinePainter(
        lineIndex: lineFrom,
        textScaler: textScaler,
        color: color,
        letterSpacing: letterSpacing,
        scriptColor: scriptColor,
        adaptColor: adaptColor,
      );
    }
    final start = lines[lineFrom].start;
    var end = lines[lineTo - 1].end;
    // 琛岃寖鍥存妸鎹㈣绗︾畻鍦ㄨ灏撅紝淇濊瘉鍚勮棣栧熬鐩告帴锛涗絾閲嶆帓鏃舵湯灏剧殑鎹㈣浼氬鍑轰竴涓?
    // 绌鸿锛岃鏁板氨鍜屾祴閲忓涓嶄笂锛岀粯鍒朵細閫€鍖栨垚銆屼笉缁欏搴︺€嶇殑閫愯缁樺埗銆佹枃瀛楀啿鍑?
    // 寮曠敤妗嗭紡浠ｇ爜妗嗐€傚唴閮ㄦ崲琛屽繀椤讳繚鐣欙紝鍙幓鎺夌粨灏剧殑鎹㈣銆?
    while (end > start && text.codeUnitAt(end - 1) == 0x0A) {
      end--;
    }
    return TextPainter(
      text: TextSpan(
        children: _paintSpans(
          start,
          end,
          color,
          letterSpacing,
          scriptColor,
          adaptColor,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
  }

  /// 鍗曡鐗囨锛氫笉缁欐柇琛屽搴︼紝鎺掑嚭鏉ユ案杩滄槸涓€琛屻€?
  ///
  /// 缁?[createFragmentPainter] 鍏滃簳鐢ㄣ€傝瀹芥濂介《鍒板唴瀹瑰銆佹垨鑰呰灏炬爣鐐瑰湪瀛椾綋
  /// 鍥為€€鍚庢嬁鍒版洿瀹界殑鍐欐硶鏃讹紝鏁存閲嶆帓浼氭瘮娴嬮噺鏃跺鎶樺嚭涓€琛岋紝澶氬嚭鏉ョ殑閭ｈ鍘嬪湪
  /// 涓嬩竴琛屼笂锛堢湡鏈哄疄娴嬶細涓や釜瀛楀彔鍦ㄤ竴璧凤紝鐪嬬潃鍍忓皯浜嗗瓧锛夈€傞€愯鐢诲氨娌℃湁杩欎釜椋庨櫓銆?
  TextPainter createSingleLinePainter({
    required int lineIndex,
    required TextScaler textScaler,
    Color? color,
    double letterSpacing = 0,
    Color? scriptColor,
    Color Function(Color, Color?)? adaptColor,
  }) {
    final line = lines[lineIndex];
    // 涓?createFragmentPainter 鐩稿悓锛氳灏剧殑鎹㈣绗︿笉杩涚粯鍒舵枃鏈?
    var end = line.end;
    while (end > line.start && text.codeUnitAt(end - 1) == 0x0A) {
      end--;
    }
    final span = TextSpan(
      children: _paintSpans(
        line.start,
        end,
        color,
        letterSpacing,
        scriptColor,
        adaptColor,
      ),
    );
    if (letterSpacing > 0) {
      return EdgeAlignedTextPainter(
        text: span,
        textScaler: textScaler,
        spacing: letterSpacing,
        fixedPrefixLength: (displayPrefixLength - line.start).clamp(
          0,
          end - line.start,
        ),
      )..layout();
    }
    return TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
  }

  Color? _inlineBackgroundAt(int offset) {
    Color? background;
    for (final p in inlineBoxes) {
      if (p.span.start <= offset &&
          offset < p.span.end &&
          p.box.background != null) {
        background = p.box.background;
      }
    }
    return background;
  }

  /// 鍙?[start, end) 鍖洪棿鐢ㄤ簬缁樺埗鐨?span锛岃鐩栭鑹蹭笌瀛楄窛銆?
  List<InlineSpan> _paintSpans(
    int start,
    int end,
    Color? color,
    double letterSpacing, [
    Color? scriptColor,
    Color Function(Color, Color?)? adaptColor,
  ]) {
    final hyphen = lines.any((line) => line.end == end && line.hyphenated);
    // 行尾折叠空格属于定位范围，但不属于可见文字和下划线的宽度。
    if (lines.any((line) => line.end == end)) {
      while (end > start && text.codeUnitAt(end - 1) == 0x20) {
        end--;
      }
    }
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < runs.length; i++) {
      final run = runs[i];
      final runStart = cursor;
      final runEnd = cursor + run.text.length;
      cursor = runEnd;
      if (runEnd <= start || runStart >= end) continue;
      final from = (start > runStart ? start : runStart) - runStart;
      final to = (end < runEnd ? end : runEnd) - runStart;
      if (to <= from) continue;
      final own = runStyles[i].color;
      final paintColor = run.isScript
          ? scriptColor
          : own == null
          ? color
          : (adaptColor?.call(
                  own,
                  _inlineBackgroundAt(math.max(start, runStart)),
                ) ??
                own);
      // 阅读器补的首行缩进是固定留白，不属于可拉伸的正文字符。分界可能落在
      // 同一个 run 内，必须先拆开再设置字距；测量、选文和绘制共用这些 span。
      final split = (displayPrefixLength - runStart).clamp(from, to);
      if (split > from) {
        spans.add(
          FixedIndent.span(
            run.text.substring(from, split),
            runStyles[i].copyWith(color: paintColor),
          ),
        );
      }
      if (to > split) {
        spans.add(
          TextSpan(
            text: run.text.substring(split, to),
            style: runStyles[i].copyWith(
              color: paintColor,
              letterSpacing: letterSpacing == 0 ? null : letterSpacing,
            ),
          ),
        );
      }
    }
    if (hyphen) {
      spans.add(
        TextSpan(
          text: '-',
          style: spans.isEmpty
              ? null
              : (spans.last as TextSpan).style?.copyWith(
                  letterSpacing: letterSpacing,
                ),
        ),
      );
    }
    return spans;
  }

  /// 杩欎竴琛岀粯鍒舵椂瑕佹憡寮€鐨勫瓧璺濓紙0 琛ㄧず鍘熸牱鐢伙級銆?
  ///
  /// 琛屽熬绌烘。鏈変袱涓潵婧愶細涓€鏄父鏈夌殑銆屼笅涓€涓瓧鏀句笉涓嬨€嶏紙涓嶅埌涓€涓瓧瀹斤級锛?
  /// 浜屾槸涓枃閬垮ご灏锯€斺€斾笅涓€涓瓧鏀惧緱涓嬶紝浣嗗畠鍚庨潰鐨勬爣鐐逛笉鍏佽鍑虹幇鍦ㄨ棣栵紝
  /// 浜庢槸鏁磋鎻愬墠鏀跺熬锛岀┖鍑烘暣鏁翠竴涓埌涓や釜瀛椼€傜浜岀鍦ㄩ槄璇绘椂鍍忔槸銆屽皯浜嗗瓧銆嶏紝
  /// 杩欓噷鎸夊瓧璺濇憡骞冲埌鏁磋锛岃姣忎竴琛岄兘椤跺埌鍙宠竟銆?
  ///
  /// 娈佃惤鏈€鍚庝竴琛屽拰鏍囬涓嶆媺浼革紱鍏朵綑鏈夌┖妗ｇ殑琛岄兘鎽婂紑锛屼笉鎸夌┖妗ｅぇ灏忕瓫閫夈€?
  double justifySpacingFor(
    int lineIndex, {
    required double maxWidth,
    required bool enabled,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (!enabled || lineIndex >= lines.length - 1) return 0;
    final cache = _spacingCache[this] ??= {};
    final key = (lineIndex, maxWidth, textScaler);
    return cache.putIfAbsent(key, () {
      double width(double spacing) {
        final painter = createSingleLinePainter(
          lineIndex: lineIndex,
          textScaler: textScaler,
          letterSpacing: spacing,
        );
        final width = painter.computeLineMetrics().first.width;
        painter.dispose();
        return width;
      }

      // 鐢ㄥ疄闄呭瓧浣撴祴閲忓瓧璺濆閲忥紝閬垮厤鏍囩偣鍘嬬缉銆佹贩鍚堝瓧閲嶅拰绯荤粺缂╂斁鐣欎笅绌虹己銆?
      // 缂撳瓨璺熼殢鍧楅噴鏀撅紱缁樺埗銆侀€夋枃涓庡惉涔﹂珮浜鍙栧悓涓€涓粨鏋溿€?
      final natural = width(0);
      if (natural >= maxWidth) return 0;
      final gain = width(1) - natural;
      if (gain <= 0) return 0;
      return (maxWidth - natural) / gain;
    });
  }

  static final _spacingCache =
      Expando<Map<(int, double, TextScaler), double>>();

  /// 琛屽唴鍥剧墖涔嬮棿鐨勬枃瀛楁鍗曠嫭缁樺埗锛氬彧鎺掕繖涓€娈碉紝璧风偣鐢辨祴閲忕粨鏋滅粰鍑恒€?
  ///
  /// 涓嶈兘鐢ㄦ暣琛岄噸鎺掞紝鍚﹀垯鍥剧墖鍗犵殑瀹藉害涓嶄細琚畻杩涘幓锛屽浘鐗囧悗闈㈢殑鏂囧瓧浼氬帇鍒板浘鐗囦笂銆?
  TextPainter createSegmentPainter({
    required int start,
    required int end,
    required TextScaler textScaler,
    double letterSpacing = 0,
    Color? color,
    Color? scriptColor,
    Color Function(Color, Color?)? adaptColor,
  }) {
    final span = TextSpan(
      children: _paintSpans(
        start,
        end,
        color,
        letterSpacing,
        scriptColor,
        adaptColor,
      ),
    );
    if (letterSpacing > 0) {
      return EdgeAlignedTextPainter(
        text: span,
        textScaler: textScaler,
        spacing: letterSpacing,
        fixedPrefixLength: (displayPrefixLength - start).clamp(0, end - start),
      )..layout();
    }
    return TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
  }

  /// 鍙?[lineIndex] 琛岄噷鍖呭惈 [offset] 鐨勬枃瀛楁锛涙病鏈夊垎娈垫椂杩斿洖 null銆?
  MeasuredSegment? segmentAtOffset(int lineIndex, int offset) {
    final line = lines[lineIndex];
    for (final segment in line.segments) {
      if (offset >= segment.start && offset <= segment.end) return segment;
    }
    return line.segments.isEmpty ? null : line.segments.last;
  }

  /// 鎸夋í鍧愭爣鎵炬枃瀛楁锛氳繑鍥炲懡涓殑娈靛拰娈靛唴鐩稿 x銆?
  ({MeasuredSegment segment, double dx})? segmentAtX(int lineIndex, double x) {
    final line = lines[lineIndex];
    for (final segment in line.segments) {
      if (x <= segment.left + segment.width) {
        return (segment: segment, dx: math.max(0, x - segment.left));
      }
    }
    return line.segments.isEmpty
        ? null
        : (segment: line.segments.last, dx: line.segments.last.width);
  }

  /// 鍙?[lineIndex] 琛岄噷鍖呭惈 [offset] 鐨勮鍐呭浘鐗囷紱娌℃湁鏃惰繑鍥?null銆?
  InlineImagePlacement? imageAtOffset(int lineIndex, int offset) {
    for (final image in inlineImages) {
      if (image.line == lineIndex && image.offset == offset) return image;
    }
    return null;
  }

  /// 鍙?[start, end) 鍖洪棿鐨勬牱寮忕墖娈碉紝渚涚粯鍒跺崟琛屼娇鐢ㄣ€?
  ///
  /// 鐩寸櫧鍦版寜 run 杈圭晫鍒囩墖锛氫竴涓鐗囨鍙兘妯法鍔犵矖涓庨潪鍔犵矖涓ゆ銆?
  List<InlineSpan> spansFor(int start, int end) {
    if (runs.isEmpty) return const [];
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < runs.length; i++) {
      final run = runs[i];
      final runStart = cursor;
      final runEnd = cursor + run.text.length;
      cursor = runEnd;
      if (runEnd <= start || runStart >= end) continue;
      final from = (start > runStart ? start : runStart) - runStart;
      final to = (end < runEnd ? end : runEnd) - runStart;
      if (to <= from) continue;
      spans.add(
        TextSpan(text: run.text.substring(from, to), style: runStyles[i]),
      );
    }
    return spans;
  }
}
