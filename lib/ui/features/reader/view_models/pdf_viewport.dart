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
  double scale = 1;
  Offset offset = Offset.zero;
  bool editing = false, touching = false, busy = false;
  int revision = 0;
  bool get canTurn => !editing && !touching && !busy;
  // 确认只收起本轮菜单，固定的比例和偏移继续用于后续翻页。
  bool get menuVisible => editing;

  void begin() {
    editing = true;
    touching = true;
    revision++;
    notifyListeners();
  }

  void update(double value, Offset translation) {
    scale = value.clamp(.5, 2.0);
    offset = translation;
    notifyListeners();
  }

  void end() {
    touching = false;
    // 接近原大小时自动归位；100%但已拖移的视窗仍需固定或重置。
    if ((scale - 1).abs() < .005 && offset.distance < 1) {
      scale = 1;
      offset = Offset.zero;
      editing = false;
    }
    notifyListeners();
  }

  void confirm({bool reset = false, bool scroll = false}) {
    if (reset) {
      scale = 1;
      offset = Offset.zero;
    } else if (scroll) {
      // 纵向位移已经换算进滚动位置，之后由连续列表接管。
      offset = Offset(offset.dx, 0);
    }
    editing = false;
    busy = false;
    revision++;
    notifyListeners();
  }

  void preparing(bool value) {
    busy = value;
    notifyListeners();
  }
}
