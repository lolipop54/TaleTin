/// 按需正文所需的最小来源信息。版本只描述存储方式，不改变正文坐标。
class SourceContentIndex {
  const SourceContentIndex({
    required this.format,
    required this.sourceDigest,
    required this.sourceBytes,
    required this.chapters,
    this.charset = '',
    this.images = const {},
    this.sourceStamp,
    this.publication = const {},
    this.mobiIndex = const {},
    this.tocPositions = const {},
    this.tocHeadings = const {},
  });

  final String format, sourceDigest, charset;
  final int sourceBytes;

  /// 建立索引并核对期间的源文件状态，不替代内容摘要。
  final String? sourceStamp;

  /// TXT 为原文件中的 [起始字节, 结束字节]；EPUB 为 [ZIP 条目路径]，
  /// MOBI／AZW3 为 [重建目录中的章节路径]，PDF为 [从0开始的原页码]。
  final Map<String, List<Object>> chapters;

  /// 已确认存在的图片尺寸；[-1, -1] 表示等实际读章再探测并提取。
  /// 只读搜索/定位保留图片块和路径，不提取资源。
  final Map<String, List<int>> images;

  /// MOBI/AZW3 重建文件的摘要；备份和读章均核对，不能混用损坏或旧产物。
  final Map<String, String> publication;

  /// Direct MOBI recipes are bound to the exact source and index bytes. This
  /// storage version does not change chapter ids, body offsets or body rules.
  final Map<String, Object> mobiIndex;

  /// Small chapter-relative TOC fractions, produced with the original-book
  /// sanitizer and Locator rules. Missing/unsupported anchors use the old reader.
  final Map<String, Map<String, double?>> tocPositions;

  /// Heading fallbacks use the standard body, rather than the original DOM.
  final Map<String, Map<String, double>> tocHeadings;
  bool get directMobi => mobiIndex.isNotEmpty;

  Map<String, Object?> toJson() => {
    'version': directMobi ? 2 : 1,
    'format': format,
    'sourceDigest': sourceDigest,
    'sourceBytes': sourceBytes,
    if (sourceStamp != null) 'sourceStamp': sourceStamp,
    if (charset.isNotEmpty) 'charset': charset,
    'chapters': chapters,
    if (images.isNotEmpty) 'images': images,
    if (publication.isNotEmpty) 'publication': publication,
    if (directMobi) 'mobiIndex': mobiIndex,
    if (tocPositions.isNotEmpty) 'tocPositions1': tocPositions,
    if (tocHeadings.isNotEmpty) 'tocHeadings1': tocHeadings,
  };

  factory SourceContentIndex.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 && json['version'] != 2) {
      throw const FormatException('不支持的正文索引');
    }
    final direct = (json['mobiIndex'] as Map? ?? {}).cast<String, Object>();
    if (json['version'] == 2 &&
        (!{'mobi', 'azw3'}.contains(json['format']) ||
            (json['publication'] as Map? ?? {}).isNotEmpty ||
            direct['bytes'] is! int ||
            (direct['bytes'] as int) < 12 ||
            (direct['bytes'] as int) > 50 * 1024 * 1024 ||
            direct['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(direct['sha256'] as String))) {
      throw const FormatException('MOBI读取索引证明无效');
    }
    if (json['version'] == 1 && direct.isNotEmpty) {
      throw const FormatException('正文索引版本与存储方式不一致');
    }
    return SourceContentIndex(
      format: json['format'] as String,
      sourceDigest: json['sourceDigest'] as String,
      sourceBytes: json['sourceBytes'] as int,
      sourceStamp: json['sourceStamp'] as String?,
      charset: json['charset'] as String? ?? '',
      chapters: (json['chapters'] as Map).map(
        (key, value) => MapEntry(key as String, (value as List).cast<Object>()),
      ),
      images: (json['images'] as Map? ?? {}).map(
        (key, value) => MapEntry(key as String, (value as List).cast<int>()),
      ),
      publication: Map<String, String>.from(json['publication'] as Map? ?? {}),
      mobiIndex: direct,
      tocPositions: (json['tocPositions1'] as Map? ?? {}).map(
        (chapter, positions) => MapEntry(
          chapter as String,
          (positions as Map).map((fragment, fraction) {
            final value = (fraction as num?)?.toDouble();
            if (value != null && (!value.isFinite || value < 0 || value > 1)) {
              throw const FormatException('目录位置无效');
            }
            return MapEntry(fragment as String, value);
          }),
        ),
      ),
      tocHeadings: (json['tocHeadings1'] as Map? ?? {}).map(
        (chapter, headings) => MapEntry(
          chapter as String,
          (headings as Map).map((title, fraction) {
            final value = (fraction as num).toDouble();
            if (!value.isFinite || value < 0 || value > 1) {
              throw const FormatException('目录标题位置无效');
            }
            return MapEntry(title as String, value);
          }),
        ),
      ),
    );
  }
}
