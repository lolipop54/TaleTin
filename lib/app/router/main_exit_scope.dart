import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/channels/system_toast.dart';

/// 只挂在主导航外壳上；子路由和书架多选先处理自己的返回。
class MainExitScope extends StatefulWidget {
  const MainExitScope({super.key, required this.child});

  final Widget child;

  @override
  State<MainExitScope> createState() => _MainExitScopeState();
}

class _MainExitScopeState extends State<MainExitScope> {
  static const _interval = Duration(seconds: 2);
  Timer? _exitTimer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onInactive: _reset,
      onResume: () {
        _reset();
        // audio_service 复用 FlutterEngine，Activity 重建后原生的返回回调需重新登记。
        // PopScope 的值没有变化时框架不会主动重发，否则返回键会直接交给桌面。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(SystemNavigator.setFrameworkHandlesBack(true));
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      },
    );
  }

  void _reset() {
    if (_exitTimer == null) return;
    _exitTimer?.cancel();
    _exitTimer = null;
    unawaited(SystemToast.cancel());
  }

  void _onBack(bool didPop, Object? result) {
    if (didPop) return;
    if (_exitTimer?.isActive ?? false) {
      _reset();
      // 交给 Android 正常关闭界面，不强杀进程，保留既有后台听书行为。
      unawaited(SystemNavigator.pop());
      return;
    }
    unawaited(SystemToast.show('再按一次返回键退出应用'));
    _exitTimer = Timer(_interval, _reset);
  }

  @override
  void dispose() {
    _reset();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: _onBack,
    child: Listener(
      // 点击页面、切换主导航或进入子页后，下一次返回重新计数。
      onPointerDown: (_) => _reset(),
      child: widget.child,
    ),
  );
}
