import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final pdfViewportProvider = Provider.autoDispose.family<PdfViewport, String>((
  ref,
  id,
) {
  final view = PdfViewport();
  ref.onDispose(view.dispose);
  return view;
});

/// 只保存本次阅读的视窗。缩放不改正文坐标、书签或源PDF。
class PdfViewport extends ChangeNotifier {
  static const minScale = .5, maxScale = 5.0;

  double scale = 1;
  Offset offset = Offset.zero;
  bool editing = false, touching = false, busy = false;
  Offset _unsnapped = Offset.zero;
  bool _snapX = false, _snapY = false;
  int revision = 0;
  bool get menuVisible => editing;
  bool get canTurn => !editing && !touching && !busy;
  bool canUseReadingGestures({required bool fixedView}) =>
      canTurn && (fixedView || scale <= 1);

  void begin({bool fixedView = false}) {
    editing = fixedView;
    touching = true;
    rebaseFixedDrag();
    revision++;
    notifyListeners();
  }

  void rebaseFixedDrag() {
    _unsnapped = offset;
    _snapX = offset.dx.abs() < 1;
    _snapY = offset.dy.abs() < 1;
  }

  /// 用未吸附的位置累计单指位移，使连续小步拖动也能离开中心。
  Offset fixedDrag(Offset delta) {
    _unsnapped += delta;
    _snapX = _unsnapped.dx.abs() <= (_snapX ? 22 : 12);
    _snapY = _unsnapped.dy.abs() <= (_snapY ? 22 : 12);
    return Offset(_snapX ? 0 : _unsnapped.dx, _snapY ? 0 : _unsnapped.dy);
  }

  void update(double value, Offset translation) {
    scale = value.clamp(minScale, maxScale);
    offset = translation;
    notifyListeners();
  }

  void end() {
    touching = false;
    notifyListeners();
  }

  void confirm({bool reset = false, Offset? landing, double? appliedScale}) {
    if (reset) {
      scale = 1;
      offset = Offset.zero;
      revision++;
    } else if (landing != null) {
      offset = landing;
    }
    if (appliedScale != null) scale = appliedScale;
    editing = false;
    busy = false;
    notifyListeners();
  }

  void preparing(bool value) {
    busy = value;
    notifyListeners();
  }
}
