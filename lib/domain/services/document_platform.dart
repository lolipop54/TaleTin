/// 文件选择与读取的平台能力契约。
///
/// Android 侧支持 SAF 文档 URI 与应用内浏览得到的本地文件 URI：
/// URI 内容按固定大小分块拉取，Dart 侧边写暂存边算哈希
/// （设计文档 6.1「URI 分块传输」）。
library;

import 'dart:typed_data';

/// 用户选中的一个文档。
class PickedDocument {
  const PickedDocument({
    required this.uri,
    required this.name,
    this.sizeBytes,
  });

  /// SAF 文档 URI 或应用内浏览产生的 file URI
  final String uri;

  /// 显示名（含扩展名）
  final String name;

  /// 平台报告的字节数；可能为 null（个别提供方不返回大小）
  final int? sizeBytes;
}

/// 已打开文档的读取会话。
class DocumentSession {
  const DocumentSession({required this.id, this.sizeBytes});

  /// 平台侧会话 ID，用于分块读取与关闭
  final int id;
  final int? sizeBytes;
}

/// 平台文档能力。
abstract class DocumentPlatform {
  /// 多选文件；用户取消选择时返回空列表。
  Future<List<PickedDocument>> pickDocuments();

  Future<DocumentSession> open(String uri);

  /// 读取下一块；已到末尾返回 null。块大小由平台侧限制在 ~1 MiB。
  Future<Uint8List?> readChunk(DocumentSession session, int maxBytes);

  Future<void> close(DocumentSession session);

  /// 保留平台解码用于诊断对照；正式 TXT 编码预览使用 Rust。
  ///
  /// 平台无法识别字符集时抛 [ArgumentError]。
  Future<String> decodeBytes(Uint8List bytes, String charsetName);

  /// 把整个文件按指定字符集转成 UTF-8 写入目标路径。
  ///
  /// 诊断时与 Rust 转码比较输出和耗时。返回平台实际使用的字符集名；
  /// 正式正文及旧书修复的转码不再调用本方法。
  Future<String> transcodeToUtf8({
    required String sourcePath,
    required String charsetName,
    required String targetPath,
  });

  /// 指定路径所在卷的剩余可用字节，用于导入前的空间校验。
  Future<int> availableBytes(String path);

  /// 平台支持的字符集名候选（用于「手动切换编码」列表）。
  Future<List<String>> supportedCharsets();
}
