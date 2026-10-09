import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_list_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/gt_icon.dart';

final _pendingPages = <ModalRoute<dynamic>?, Object>{};

/// 需要设备数据的页面先在原页准备；订阅持续到返回，避免自动释放后重复加载。
Future<void> openSettingsPage<T>(
  BuildContext context,
  Widget page, {
  ProviderListenable<Future<T>>? ready,
}) async {
  final container = ProviderScope.containerOf(context);
  final origin = ModalRoute.of(context);
  final request = Object();
  _pendingPages[origin] = request;
  final subscription = ready == null
      ? null
      : container.listen(ready, (_, _) {});
  try {
    if (subscription != null) await subscription.read();
    // 准备期间切换主导航或再次点击其它入口，以用户最后的操作为准。
    if (!context.mounted ||
        origin?.isCurrent == false ||
        _pendingPages[origin] != request ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    final reduced = MediaQuery.disableAnimationsOf(context);
    final motion = context.gtMotion;
    // 子页由最外层导航打开，覆盖整个主界面；底栏只属于三个主页。
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        transitionDuration: reduced
            ? const Duration(milliseconds: 150)
            : motion.panelIn,
        reverseTransitionDuration: reduced
            ? const Duration(milliseconds: 150)
            : motion.panelExit,
        pageBuilder: (_, _, _) =>
            UncontrolledProviderScope(container: container, child: page),
        transitionsBuilder: (_, animation, _, child) => reduced
            ? FadeTransition(opacity: animation, child: child)
            : SlideTransition(
                position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                    .animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: motion.curveEnter,
                      ),
                    ),
                child: child,
              ),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设置页面准备失败，请重试')));
    }
  } finally {
    subscription?.close();
    if (_pendingPages[origin] == request) _pendingPages.remove(origin);
  }
}

/// 共用选项页面：选中项使用当前主题的主色，右侧勾号同色，不改变字重。
class SettingsChoices<T> extends ConsumerStatefulWidget {
  const SettingsChoices({
    super.key,
    required this.title,
    required this.options,
    required this.label,
    required this.selected,
    required this.save,
    this.optionStyle,
    this.leading,
  });
  final String title;
  final Widget? leading;
  final List<T> options;
  final String Function(T) label;
  final T Function(WidgetRef) selected;
  final Future<void> Function(WidgetRef, T) save;

  /// 字体选项用真实字体预览，仍由共用列表负责完整名称换行和保存状态。
  final TextStyle Function(T, bool)? optionStyle;
  @override
  ConsumerState<SettingsChoices<T>> createState() => _SettingsChoicesState<T>();
}

class _SettingsChoicesState<T> extends ConsumerState<SettingsChoices<T>> {
  bool _saving = false;
  @override
  Widget build(BuildContext context) {
    final selected = widget.selected(ref);
    return Scaffold(
      appBar: GtAppBar(title: Text(widget.title)),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
          itemCount: widget.options.length + (widget.leading == null ? 0 : 1),
          separatorBuilder: (_, _) => const Divider(),
          itemBuilder: (context, index) {
            if (widget.leading != null && index == 0) return widget.leading!;
            final option =
                widget.options[index - (widget.leading == null ? 0 : 1)];
            final active = option == selected;
            return GtListButton(
              selected: active,
              contentPadding: EdgeInsets.zero,
              minTileHeight: 48,
              title: Text(
                widget.label(option),
                style:
                    widget.optionStyle?.call(option, active) ??
                    GtText.body(
                      active
                          ? context.gtColors.actionPrimary
                          : context.gtColors.textPrimary,
                    ),
              ),
              trailing: active
                  ? GtIcon(
                      GtIcons.check,
                      size: 20,
                      color: context.gtColors.actionPrimary,
                    )
                  : null,
              onPressed: _saving ? null : () => _select(option),
            );
          },
        ),
      ),
    );
  }

  Future<void> _select(T option) async {
    if (option == widget.selected(ref)) return;
    setState(() => _saving = true);
    try {
      await widget.save(ref, option);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('设置未保存，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
