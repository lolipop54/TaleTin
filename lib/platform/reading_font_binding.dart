import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/diagnostics/reader_turn_diagnostics.dart';

/// 书内字体有独立别名。新章可以立即用它排字，把全应用的字体变化通知留到停稳后。
class ReadingFontBinding extends WidgetsFlutterBinding {
  static int _bookRegistrations = 0;
  final _movingReaders = <Object>{};
  bool _pendingFonts = false;
  Timer? _settled;

  static Future<void> registerBookFont(FontLoader loader) async {
    _bookRegistrations++;
    try {
      await loader.load();
    } finally {
      _bookRegistrations--;
    }
  }

  void setReaderMoving(Object reader, bool moving, {bool closing = false}) {
    if (moving) {
      _movingReaders.add(reader);
      _settled?.cancel();
      return;
    }
    _movingReaders.remove(reader);
    if (_movingReaders.isNotEmpty || !_pendingFonts) return;
    _settled?.cancel();
    if (closing) {
      _sendPendingFonts();
    } else {
      // 再次按下会短暂停住惯性。等这段交接结束，避免在下一次起拖时集中重排。
      _settled = Timer(const Duration(milliseconds: 160), _sendPendingFonts);
    }
  }

  void _sendPendingFonts() {
    _pendingFonts = false;
    unawaited(
      super.handleSystemMessage(const <String, dynamic>{'type': 'fontsChange'}),
    );
  }

  @override
  Future<void> handleSystemMessage(Object systemMessage) {
    if (_bookRegistrations > 0 &&
        _movingReaders.isNotEmpty &&
        systemMessage is Map &&
        systemMessage['type'] == 'fontsChange') {
      _pendingFonts = true;
      ReaderTurnDiagnostics.active?.event('reader.deferBookFontRefresh');
      return Future<void>.value();
    }
    return super.handleSystemMessage(systemMessage);
  }
}
