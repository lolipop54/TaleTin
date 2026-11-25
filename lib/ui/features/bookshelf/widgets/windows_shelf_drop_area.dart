import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/diagnostics/app_errors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';

class WindowsShelfDropArea extends StatefulWidget {
  const WindowsShelfDropArea({
    super.key,
    required this.enabled,
    required this.onDrop,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<List<String>> onDrop;
  final Widget child;

  @override
  State<WindowsShelfDropArea> createState() => _WindowsShelfDropAreaState();
}

class _WindowsShelfDropAreaState extends State<WindowsShelfDropArea> {
  static const _channel = MethodChannel('taletin/windows_file_drop');
  Rect? _bounds;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_receive);
  }

  @override
  void didUpdateWidget(WindowsShelfDropArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _hover = false;
      _sendBounds(null);
    }
  }

  Future<void> _receive(MethodCall call) async {
    if (!mounted || !widget.enabled) return;
    final hover = call.method == 'hover' && call.arguments == true;
    if (_hover != hover) setState(() => _hover = hover);
    if (call.method == 'drop' && call.arguments is List) {
      widget.onDrop(
        (call.arguments as List<Object?>).whereType<String>().toList(),
      );
    }
  }

  void _sendBounds(Rect? bounds) {
    if (_bounds == bounds) return;
    _bounds = bounds;
    unawaited(
      _channel
          .invokeMethod<void>(
            'setBounds',
            bounds == null
                ? null
                : [bounds.left, bounds.top, bounds.right, bounds.bottom],
          )
          .onError((Object error, StackTrace stack) {
            if (error is! MissingPluginException) {
              AppErrors.report(
                error,
                stack,
                operation: '设置书架拖放范围失败',
                notify: false,
              );
            }
          }),
    );
  }

  @override
  void dispose() {
    _sendBounds(null);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final colors = context.gtColors;
    final accent = colors.actionPrimary;
    return LayoutBuilder(
      builder: (context, _) {
        // Windows 需要实际客户区坐标，侧栏、窗口缩放和显示缩放都在布局后反映。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !context.mounted || !widget.enabled) return;
          final box = context.findRenderObject();
          if (box is RenderBox && box.hasSize) {
            final origin = box.localToGlobal(Offset.zero);
            _sendBounds(
              Rect.fromLTWH(
                origin.dx * ratio,
                origin.dy * ratio,
                box.size.width * ratio,
                box.size.height * ratio,
              ),
            );
          }
        });
        return Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (_hover)
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: DecoratedBox(
                      key: const ValueKey('windows-shelf-drop-highlight'),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: .07),
                        border: Border.all(
                          color: accent.withValues(alpha: .72),
                          width: 1.5,
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surface,
                            border: Border.all(color: colors.borderSubtle),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .12),
                                blurRadius: 22,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GtIcon(
                                GtIcons.folderPlus,
                                size: 23,
                                color: accent,
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  '松开导入书籍',
                                  style: GtText.body(
                                    colors.textPrimary,
                                    weight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
