// 应用平台通道定义：文档读写（设计文档 6.1「URI 分块传输」）+ 设备能力。
//
// 两个 @HostApi 放在同一个文件里：pigeon 会为每个文件生成一份 FlutterError，
// 拆成两个文件会撞名（Kotlin 侧同一个包内重复声明）。
//
// 生成命令：
//   dart run pigeon --input pigeons/document_host_api.dart \
//     --dart_out lib/platform/channels/document_host_api.g.dart \
//     --kotlin_out android/app/src/main/kotlin/com/example/gtreader/DocumentHostApi.g.kt \
//     --kotlin_package com.example.gtreader
//
// 约定：
// - 文件选择走 Android SAF（ACTION_OPEN_DOCUMENT + EXTRA_ALLOW_MULTIPLE），
//   不申请「所有文件访问」权限；
// - URI 内容按块拉取（约 1 MiB），Dart 侧边写暂存边算 SHA-256，
//   不经平台通道一次传整本大文件；
// - 读写与转码都是阻塞 IO，放在串行后台线程队列，避免卡住平台主线程。
import 'package:pigeon/pigeon.dart';

/// 用户选中的一个文档。
class PickedDocumentDto {
  PickedDocumentDto({required this.uri, required this.name, this.sizeBytes});

  String uri;
  String name;
  int? sizeBytes;
}

/// 已打开文档的读取会话（平台侧持有输入流）。
class DocumentSessionDto {
  DocumentSessionDto({required this.id, this.sizeBytes});

  int id;
  int? sizeBytes;
}

@HostApi()
abstract class DocumentHostApi {
  /// 多选文件。选择器由主线程弹出，本方法在后台线程等待结果，
  /// 避免阻塞平台主线程。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<PickedDocumentDto> pickDocuments();

  DocumentSessionDto openDocument(String uri);

  /// 读取下一块；已到末尾返回 null。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  Uint8List? readDocumentChunk(int sessionId, int maxBytes);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void closeDocument(int sessionId);

  /// 用指定字符集解码一段字节（TXT 编码预览），无法识别时抛错。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  String decodeBytes(Uint8List bytes, String charsetName);

  /// 把整个文件转成 UTF-8，返回实际使用的字符集名。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  String transcodeToUtf8(
      String sourcePath, String charsetName, String targetPath);

  /// 指定目录所在卷的剩余可用字节（导入前的空间校验）。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  int availableBytes(String path);

  /// 供「手动切换编码」使用的字符集候选。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<String> supportedCharsets();
}

/// 一个字体族的解析结果。
class FontFamilyDto {
  FontFamilyDto({required this.requested, this.resolved});

  /// 我们请求的字体族名；空串表示系统默认字体
  String requested;

  /// 系统实际使用的字体族名；系统里没有这个族（回退到默认）时为 null
  String? resolved;
}

/// 设备能力：目前是字体名解析，S14 的窗口亮度也走这里。
@HostApi()
abstract class DeviceHostApi {
  /// 解析字体族对应的系统字体名（Android 10+ 提供）。
  ///
  /// 返回顺序与入参一致；拿不到结果时 `resolved` 为 null。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<FontFamilyDto> resolveFontFamilies(List<String> families);

  /// 设置窗口亮度 0–1；传 null 恢复跟随系统（离开阅读页时用）。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void setWindowBrightness(double? value);

  /// 系统亮度 0–1；拿不到时返回 null。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  double? systemBrightness();

  /// 电量百分比 0–100；拿不到时返回 null。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  int? batteryLevel();
}
