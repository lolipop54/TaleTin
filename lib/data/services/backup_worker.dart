import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import '../../domain/models/backup_operation.dart';

/// 压缩、校验和等重工作放后台 isolate；取消标记跨 isolate 可见。
Future<T> runBackupWorker<T>(Directory work, BackupOperation operation,
    Future<T> Function(SendPort progress, String cancelPath) action) async {
  final token = await work.createTemp('worker-');
  final cancelPath = '${token.path}/cancel';
  final port = ReceivePort();
  final subscription = port.listen((dynamic message) {
    final values = message as List;
    operation.onProgress?.call(values[0] as String, values[1] as int, values[2] as int);
  });
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (operation.cancelled) File(cancelPath).writeAsStringSync('cancel');
  });
  final sender = port.sendPort;
  try {
    operation.check();
    return await _startWorker(action, sender, cancelPath);
  } finally {
    timer.cancel(); await subscription.cancel(); port.close();
    await token.delete(recursive: true);
  }
}

// 独立作用域避免 Dart 闭包共享上下文，把 UI 进度回调也发送到 isolate。
Future<T> _startWorker<T>(Future<T> Function(SendPort, String) action,
    SendPort progress, String cancelPath) => Isolate.run(() => action(progress, cancelPath));

void checkBackupWorker(String cancelPath) {
  if (File(cancelPath).existsSync()) throw const BackupCancelled();
}
