import 'dart:async';

import 'package:flutter/foundation.dart';
import 'turn_trace.dart';

/// 只管原书后台工作何时可以开始；不排队翻页，也不取消已开始的加载。
class OriginalPreloadGate extends ChangeNotifier {
  final _holds = <Object>{};
  Timer? _quiet;
  bool _disposed = false;
  int? _requestedChapter;
  bool get blocked => _holds.isNotEmpty || _quiet != null;
  int? get requestedChapter => _requestedChapter;

  void hold(Object owner) {
    if (_disposed) return;
    _quiet?.cancel();
    _quiet = null;
    if (_holds.add(owner)) {
      traceTurn('background pause holds=${_holds.length} requested=$_requestedChapter');
      notifyListeners();
    }
  }

  void release(Object owner) {
    if (_disposed) return;
    if (!_holds.remove(owner) || _holds.isNotEmpty) return;
    // 留一个短的续拖接收窗口。此时正文已可操作，只推迟后台补载。
    _quiet?.cancel();
    _quiet = Timer(const Duration(milliseconds: 120), () {
      _quiet = null;
      traceTurn('background resume requested=$_requestedChapter');
      notifyListeners();
    });
  }

  /// 用户正在跨向的邻章不属于后台工作，不能被自己的忙碌状态挡住。
  void requestChapter(int? chapter) {
    if (_disposed) return;
    if (_requestedChapter == chapter) return;
    _requestedChapter = chapter;
    notifyListeners();
  }

  bool allows(int chapter, int current) =>
      chapter == current || chapter == _requestedChapter || !blocked;

  @override
  void dispose() {
    _disposed = true;
    _quiet?.cancel();
    super.dispose();
  }
}
