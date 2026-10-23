import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/diagnostics/reader_delivery_experiments.dart';
import 'turn_trace.dart';

/// 只管原书后台工作何时可以开始；不排队翻页，也不取消已开始的加载。
class OriginalPreloadGate extends ChangeNotifier {
  final _holds = <Object>{};
  Timer? _quiet;
  bool _disposed = false;
  int? _requestedChapter;
  bool get blocked => _holds.isNotEmpty || _quiet != null;

  /// 目标已落稳、只剩开书／揭页动画时，可准备当前章直接邻页的截图。
  /// 这些是下一次真实翻页所需的前台资料；远端章节和补全索引仍暂停。
  bool get turnPreparationBlocked =>
      !ReaderDeliveryExperiments.originalNavigation
      ? blocked
      : _holds.any(
          (owner) => owner != 'display-transition' && owner != 'opening',
        );
  int? get requestedChapter => _requestedChapter;

  void hold(Object owner) {
    if (_disposed) return;
    _quiet?.cancel();
    _quiet = null;
    if (_holds.add(owner)) {
      traceTurn(
        'background pause holds=${_holds.length} requested=$_requestedChapter',
      );
      notifyListeners();
    }
  }

  void release(Object owner) {
    if (_disposed) return;
    if (!_holds.remove(owner)) return;
    if (_holds.isNotEmpty) {
      if (ReaderDeliveryExperiments.originalNavigation) notifyListeners();
      return;
    }
    // 当前页已落稳，直接邻页图立即准备；较远章节仍保留续拖安静窗口。
    _quiet?.cancel();
    _quiet = Timer(const Duration(milliseconds: 120), () {
      _quiet = null;
      traceTurn('background resume requested=$_requestedChapter');
      notifyListeners();
    });
    if (ReaderDeliveryExperiments.originalNavigation) notifyListeners();
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
