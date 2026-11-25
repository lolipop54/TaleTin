import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../platform/channels/windows_wheel_modifier.dart';
import '../../../../core/diagnostics/reader_turn_state_diagnostics.dart';

/// 只处理正文的输入，让面板、弹窗和输入框继续使用自己的键鼠操作。
class DesktopReadingInput extends StatelessWidget {
  const DesktopReadingInput({
    super.key,
    required this.scrolling,
    required this.enabled,
    required this.onTurn,
    required this.onScroll,
    this.onZoom,
    this.readWheelModifier,
    required this.child,
  });

  final bool scrolling;
  final bool Function() enabled;
  final ValueChanged<bool> onTurn;
  final ValueChanged<double> onScroll;
  final void Function(double delta, Offset position)? onZoom;
  final WheelModifier Function()? readWheelModifier;
  final Widget child;

  WheelModifier get _keyboardModifier {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return WheelModifier.other;
    }
    return keyboard.isControlPressed
        ? WheelModifier.control
        : WheelModifier.none;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final forward = scrolling
        ? LogicalKeyboardKey.arrowDown
        : LogicalKeyboardKey.arrowRight;
    final backward = scrolling
        ? LogicalKeyboardKey.arrowUp
        : LogicalKeyboardKey.arrowLeft;
    if (event.logicalKey != forward && event.logicalKey != backward ||
        _keyboardModifier != WheelModifier.none ||
        !enabled()) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      onTurn(event.logicalKey == forward);
    }
    return KeyEventResult.handled;
  }

  void _onWheel(PointerSignalEvent event) {
    if (readerTurnStateDiagnosticsEnabled && event is PointerScrollEvent) {
      ReaderTurnStateDiagnostics.wheelSignal('bodyHit', event);
    }
    if (event is! PointerScrollEvent ||
        event.kind != PointerDeviceKind.mouse ||
        event.scrollDelta.dy == 0) {
      return;
    }
    // 正文在等待或被面板遮住时，也不能绕过材料准备直接滚动内部列表。
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      event.respond(allowPlatformDefault: false);
      if (readerTurnStateDiagnosticsEnabled) {
        runZoned(
          () => _dispatchWheel(event),
          zoneValues: {#readerWheel: ReaderTurnStateDiagnostics.wheelId(event)},
        );
      } else {
        _dispatchWheel(event);
      }
    });
  }

  void _dispatchWheel(PointerScrollEvent event) {
    final allowed = enabled();
    if (readerTurnStateDiagnosticsEnabled) {
      ReaderTurnStateDiagnostics.record('wheel.resolved', {
        'inputAllowed': allowed,
      });
    }
    if (!allowed) return;
    final delta = event.scrollDelta.dy;
    final modifier = readWheelModifier?.call() ?? _keyboardModifier;
    if (readerTurnStateDiagnosticsEnabled) {
      ReaderTurnStateDiagnostics.record('wheel.dispatch', {
        'modifier': modifier.name,
        'mode': scrolling ? 'scroll' : 'page',
        'direction': delta > 0 ? 'forward' : 'backward',
      });
    }
    if (modifier == WheelModifier.control) {
      onZoom?.call(delta, event.position);
    } else if (modifier == WheelModifier.none) {
      if (scrolling) {
        onScroll(delta);
      } else {
        onTurn(delta > 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: _onKey,
    child: Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        // 半透明命中层先处理滚轮信号，点击、拖动仍交给下面的正文。
        // 内部 ScrollView 的默认滚轮实现会越过 PDF 已准备页的边界。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _onWheel,
          ),
        ),
      ],
    ),
  );
}
