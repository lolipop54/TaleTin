import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Android 用系统事件；桌面测试可注入同样的通知流。
final deviceStatusEventsProvider = Provider<Stream<Object?>>(
  (ref) => Platform.isAndroid
      ? const EventChannel('gtreader/device_status').receiveBroadcastStream()
      : const Stream.empty(),
);

/// 只在阅读信息被订阅时接收系统分钟、电量和校时通知。
/// 回到前台也重新读取，补上锁屏或后台期间的变化。
final deviceStatusChangesProvider = StreamProvider.autoDispose<int>((ref) {
  final changes = StreamController<int>();
  var revision = 0;
  void changed() => changes.add(++revision);
  final lifecycle = AppLifecycleListener(onResume: changed);
  final subscription = ref
      .watch(deviceStatusEventsProvider)
      .listen(
        (_) => changed(),
        onError: (Object error, StackTrace stack) {
          // 桌面和组件测试没有 Android 通道，仍可显示首次读取的值。
          if (error is! MissingPluginException) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stack,
                library: '阅读设备状态',
              ),
            );
          }
        },
      );
  ref.onDispose(() {
    lifecycle.dispose();
    unawaited(subscription.cancel());
    unawaited(changes.close());
  });
  return changes.stream;
});
