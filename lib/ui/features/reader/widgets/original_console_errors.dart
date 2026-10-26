import '../../../../core/diagnostics/app_errors.dart';
import '../../../../data/services/epub_source_repository.dart';

final _localFontDenied = RegExp(
  r'^Not allowed to load local resource: ((?:file|res)://.+\.(?:ttf|otf|ttc|woff2?)(?:[?#]\S*)?)$',
  caseSensitive: false,
);
final _deviceFontCors = RegExp(
  "^Access to font at '((?:file|res)://[^']+\\.(?:ttf|otf|ttc|woff2?)(?:[?#][^']*)?)' "
  "from origin 'https://$kEpubSourceHost' has been blocked by CORS policy:",
  caseSensitive: false,
);
final _sandboxDenied = RegExp(
  "^Blocked script execution in '([^']+)' because the document's frame "
  "is sandboxed and the 'allow-scripts' permission is not set\\.\$",
);

/// 浏览器的 ERROR 也包含可回退的字体请求和主动拦截，不全是脚本异常。
/// 正常字体回退不占用错误日志；预期脚本拦截只记录，未知错误继续提示。
void reportOriginalConsoleError(
  String message, {
  required String operation,
  bool sandboxedChapters = false,
}) {
  // 有些书同时列出 Kindle、多看等设备的本地字体。当前手机无法读取时，
  // 浏览器按原有字体栈回退；书内字体及阅读器字体仍由虚拟 HTTPS 地址提供。
  // 这不是应用故障，直接跳过，避免大量字体候选挤掉真正需要排查的记录。
  // Chromium 会把 res:///fonts/kt.ttf 规范成 res://fonts/kt.ttf；
  // 两种写法都属于设备字体候选，不能只认带三个斜杠的原始地址。
  if (_localFontDenied.hasMatch(message) || _deviceFontCors.hasMatch(message)) {
    return;
  }
  String? expectedOperation;
  if (sandboxedChapters) {
    final match = _sandboxDenied.firstMatch(message);
    final url = match == null ? null : Uri.tryParse(match.group(1)!);
    // 滚动页由父文档操作净化后的章节，章节 iframe 刻意不授予 allow-scripts。
    // 只接受书籍章节地址；宿主框架脚本被阻止仍属于真正的故障。
    if (url?.scheme == 'https' &&
        url?.host == kEpubSourceHost &&
        url!.pathSegments.length >= 3 &&
        !url.path.startsWith('/__gt__/') &&
        !url.path.startsWith('/__gt_fonts/')) {
      expectedOperation = '原书章节脚本已阻止';
    }
  }
  AppErrors.report(
    StateError(message),
    StackTrace.current,
    operation: expectedOperation ?? operation,
    notify: expectedOperation == null,
  );
}
