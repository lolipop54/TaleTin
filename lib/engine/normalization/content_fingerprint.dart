import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../../domain/models/book_document.dart';
import '../styles/chapter_styler.dart';
import '../styles/legacy_style_adapter.dart';

/// 同一份不可变正文只计算一次。仓库重新解码出相同正文时仍可复用原排版，
/// 不能把「Dart 对象换了」当成「书的内容换了」，也不能仅凭书号猜测相同。
///
/// 这里会算两种摘要，用途不同（见设计文档 6.5 与实施计划 P3）：
/// - [of]：整份正文（含当前还挂在块/片段上的显示字段）的摘要，
///   今天用来作废测量断点；
/// - [bodyOf]：**只算正文口径**——文字、块 ID、块类型、进度权重、图片顺序、表格映射。
///   样式表接入后，测量断点身份改成「正文摘要 + 几何样式摘要」，
///   这样只改颜色/背景/圆角不会让整章重新测量。
///
/// 为什么不能继续哈希 `content.toJson()`：把样式表放进正文以后，改一个颜色也会改变
/// 整份摘要，分页缓存全部失效；而那本来只需要重画。
abstract final class ContentFingerprint {
  static final _digests = Expando<Future<String>>();
  static Future<String> of(ChapterContent content) =>
      _digests[content] ??= _work(content, () => _digest(content));

  /// 正文后台把同一次规范编码的摘要随正文交回，排版不用再次编码整章。
  static void remember(ChapterContent content, String digest) {
    _digests[content] ??= Future.value(digest);
  }

  static String digestBytes(List<int> canonicalBytes) =>
      sha256.convert(canonicalBytes).toString();

  static final _bodyDigests = Expando<Future<String>>();
  static Future<String> bodyOf(ChapterContent content) =>
      _bodyDigests[content] ??= _work(content, () => bodyDigest(content));

  /// 大章放后台 isolate，小章直接算：两者都只算一次。
  static Future<String> _work(
    ChapterContent content,
    String Function() compute,
  ) => content.blocks.length <= 128 && content.textLength <= 8192
      ? Future.value(compute())
      : Isolate.run(compute);

  static String _digest(ChapterContent content) =>
      digestBytes(utf8.encode(jsonEncode(content.toJson())));

  /// 正文投影摘要：去掉一切「只影响显示」的字段。
  ///
  /// 去掉的内容：对齐、首行缩进开关、硬换行位置、列表层级/序号、盒子数组、
  /// 文字阴影、列表标记、图片显式宽高、分隔线线型、行内盒子，以及 run 上的
  /// 粗体/斜体/颜色/字号倍数/上下标/下划线/删除线。
  /// 这些字段在样式表接入后都会搬出正文模型，所以它们的变化不该让正文摘要变化。
  ///
  /// 保留的内容：章节 ID、块的 ID/类型/级别、每个片段的文字与链接/脚注标记、
  /// 进度权重、段内图片的位置与资源、表格行列与单元格到块的映射、PDF 页信息。
  static String bodyDigest(ChapterContent content) => sha256
      .convert(utf8.encode(jsonEncode(_bodyProjection(content))))
      .toString();

  /// 正文投影本体；测试会逐字段核对「哪些变化该影响摘要」。
  static List<Object?> bodyProjection(ChapterContent content) =>
      _bodyProjection(content);

  static List<Object?> _bodyProjection(ChapterContent content) => [
    content.chapterId,
    if (content.pdfPage != null) content.pdfPage!.toJson(),
    for (final block in content.blocks) _blockProjection(block),
    for (final table in content.tables) table.toBodyJson(),
  ];

  static List<Object?> _blockProjection(ContentBlock block) => [
    block.id,
    block.kind.code,
    block.level,
    block.weight,
    for (final run in block.runs) [run.text, run.link, run.footnote],
    for (final image in block.inlineImages)
      [image.offset, image.resourcePath, image.width, image.height],
    block.resourcePath,
    block.alt,
  ];

  /// 旧字段口径的正文：按样式表还原显示字段，再按旧口径（去掉样式传输）比较。
  static Map<String, Object?> legacyView(ChapterContent content) =>
      withoutStyleTransportJson(LegacyStyleAdapter.legacyJson(content));

  static Map<String, Object?> legacyViewJson(Map<String, Object?> json) =>
      legacyView(ChapterStyler.decode(json));

  /// 去掉批次 C 新增的样式传输字段（`styles` 表、块/片段的 `sid`）后的正文 JSON。
  ///
  /// 旧版本落盘的正文没有这些字段，新生成的正文有；核对「同一份来源重新转换后，
  /// 正文与旧显示字段是否仍然逐项相同」时必须把它们排除，否则旧 JSON 永远对不上。
  /// 这里用**旧字段完整**的形态（`LegacyStyleAdapter.legacyJson`）：正文缓存的默认
  /// 写入形态只有正文和样式表，直接 `toJson()` 会把要比较的显示字段也省掉。
  /// 样式表本身的无损性由 `legacy_style_adapter_test.dart` 单独验证。
  static Map<String, Object?> withoutStyleTransport(ChapterContent content) =>
      withoutStyleTransportJson(LegacyStyleAdapter.legacyJson(content));

  /// 同上，但输入是已经序列化的正文 JSON（迁移核对里旧文件就是这种形态）。
  static Map<String, Object?> withoutStyleTransportJson(
    Map<String, Object?> json,
  ) {
    final copy = Map<String, Object?>.from(json)..remove('styles');
    final blocks = copy['blocks'];
    if (blocks is List) {
      copy['blocks'] = [
        for (final block in blocks)
          if (block is Map) _withoutStyleIds(block) else block,
      ];
    }
    return copy;
  }

  static Map<String, Object?> _withoutStyleIds(Map<dynamic, dynamic> block) {
    final copy =
        <String, Object?>{
            for (final entry in block.entries) entry.key as String: entry.value,
          }
          ..remove('sid')
          // 外边距是批次 D1 新增的块流信息，旧 JSON 没有；迁移核对时不算正文差异。
          ..remove('mg')
          // 字距／词距是 E 批次新增的显示字段，旧 JSON 没有。
          ..remove('lsp')
          ..remove('wsp');
    final runs = copy['runs'];
    if (runs is List) {
      copy['runs'] = [
        for (final run in runs)
          if (run is Map)
            (<String, Object?>{
              for (final entry in run.entries) entry.key as String: entry.value,
            }..remove('sid'))
          else
            run,
      ];
    }
    return copy;
  }
}
