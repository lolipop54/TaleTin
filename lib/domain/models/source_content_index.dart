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
  });

  final String format, sourceDigest, charset;
  final int sourceBytes;
  /// 建立索引并核对期间的源文件状态，不替代内容摘要。
  final String? sourceStamp;

  /// TXT 为原文件中的 [起始字节, 结束字节]；EPUB 为 [ZIP 条目路径]。
  final Map<String, List<Object>> chapters;

  /// 已确认存在的图片尺寸；[-1, -1] 表示等实际读章再探测并提取。
  /// 只读搜索/定位保留图片块和路径，不提取资源。
  final Map<String, List<int>> images;

  Map<String, Object?> toJson() => {
    'version': 1,
    'format': format,
    'sourceDigest': sourceDigest,
    'sourceBytes': sourceBytes,
    if (sourceStamp != null) 'sourceStamp': sourceStamp,
    if (charset.isNotEmpty) 'charset': charset,
    'chapters': chapters,
    if (images.isNotEmpty) 'images': images,
  };

  factory SourceContentIndex.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('不支持的正文索引');
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
    );
  }
}
