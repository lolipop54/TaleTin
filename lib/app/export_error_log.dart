import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/diagnostics/app_errors.dart';
import '../platform/channels/backup_documents.dart';
import '../platform/channels/system_toast.dart';

bool _exporting = false;

/// 只有用户主动选择保存位置才导出，不上传，也不包含书库或阅读笔记。
Future<void> exportErrorLog({
  BackupDocuments? documents,
  Future<String> Function()? readLog,
}) async {
  if (_exporting) return;
  _exporting = true;
  documents ??= BackupDocuments();
  String? uri;
  var completed = false;
  try {
    final bytes = Uint8List.fromList(
      utf8.encode(await (readLog ?? AppErrors.exportText)()),
    );
    final date = DateTime.now().toIso8601String().replaceAll(':', '-');
    uri = await documents.create('TaleTin错误日志-$date.txt', 'text/plain');
    if (uri == null) return;
    await documents.open(uri);
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      await documents.write(
        Uint8List.sublistView(
          bytes,
          offset,
          math.min(offset + 65536, bytes.length),
        ),
      );
    }
    await documents.finish();
    completed = true;
    await SystemToast.show('错误日志已导出');
  } catch (error, stack) {
    var partialKept = false;
    // 完整文件已关闭后，提示通道的失败不能再触发残留文件清理。
    if (uri != null && !completed) {
      try {
        partialKept = !await documents.abort(uri);
      } catch (_) {
        partialKept = true;
      }
    }
    AppErrors.report(
      error,
      stack,
      operation: completed
          ? '日志已导出，结果提示未显示'
          : partialKept
          ? '导出失败，文件未清理'
          : '导出错误日志失败',
      notify: !completed,
    );
  } finally {
    _exporting = false;
  }
}
