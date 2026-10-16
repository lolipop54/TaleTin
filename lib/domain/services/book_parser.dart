/// 解析器契约：探测真实格式、输出统一正文模型。
///
/// 所有格式（EPUB / TXT / 后续 MOBI）都在这里统一，阅读器与业务层
/// 不感知格式差异（设计文档 4.3）。
library;

import 'dart:typed_data';

import '../models/book.dart';
import '../models/book_document.dart';
import '../models/import_job.dart';
import '../models/locator.dart';

/// 格式探测输入：文件头若干字节 + 大小 + 名称。
///
/// 以文件头为准，不信任扩展名（设计文档 6.1）。
class FileProbe {
  const FileProbe({
    required this.header,
    required this.sizeBytes,
    required this.fileName,
  });

  /// 文件开头最多 8 KiB
  final Uint8List header;
  final int sizeBytes;
  final String fileName;

  /// 名称里的扩展名（小写，不含点）；没有扩展名时为空串
  String get extension {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }
}

/// TXT 解析选项。
class TxtOptions {
  const TxtOptions({
    this.charset,
    this.chapterPattern,
    this.forceSectionFallback = false,
  });

  /// 手动指定的编码名；null 表示按检测结果
  final String? charset;

  /// 自定义章节标题正则；null 表示使用内置规则
  final String? chapterPattern;

  /// 强制按固定长度分段，不识别章节标题（原书目录不可信时使用）
  final bool forceSectionFallback;
}

/// 解析请求。
class ParseRequest {
  const ParseRequest({
    required this.format,
    required this.sourcePath,
    required this.displayName,
    required this.workDir,
    required this.contentVersion,
    this.textPath,
    this.txt,
    this.indexedContent = false,
    this.locationAnchors = const [],
  });

  /// 已探测出的真实格式
  final BookFormat format;

  /// 暂存区中的源文件（原始字节，已通过探测）
  final String sourcePath;

  /// 用户看到的文件名（含扩展名），用于回退书名
  final String displayName;

  /// 已转成 UTF-8 的正文文本路径，仅 TXT 有值
  final String? textPath;

  /// 解析产物写入目录（提交前不可见）
  final String workDir;
  final int contentVersion;
  final TxtOptions? txt;

  /// 正式导入只保存来源索引；旧文件比对和兼容测试仍可生成章节文件。
  final bool indexedContent;
  final List<Locator> locationAnchors;
}

/// 解析进度回调：0–1；null 表示无法估算，界面显示不定进度。
typedef ParseProgress = void Function(double? fraction);
typedef ParseCover = void Function(Uint8List bytes);

abstract class BookParserRegistry {
  /// 真实格式探测；返回 null 表示不支持（含阶段 6 前的 MOBI）。
  BookFormat? probe(FileProbe probe);

  /// 解析为统一正文模型。
  ///
  /// 在可取消的 worker isolate 中执行：取消即终止 worker，
  /// worker 只写 [ParseRequest.workDir] 内的暂存产物。
  Future<BookDocument> parse(
    ParseRequest request, {
    required ParseProgress onProgress,
    required CancelToken cancel,
    ParseCover? onCover,
  });
}
