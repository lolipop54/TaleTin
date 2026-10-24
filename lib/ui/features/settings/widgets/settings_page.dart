import 'package:taletin/core/diagnostics/app_errors.dart';
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
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '设置页面准备失败', notify: false);
    if (context.mounted) {
      AppErrors.report(appError, appStack, operation: '设置页面准备失败');
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
    this.actions,
    this.optionTrailing,
    this.enabled = true,
    this.onSavingChanged,
    this.onReorder,
  });
  final String title;
  final Widget? leading;
  final List<Widget>? actions;
  final Widget? Function(T, bool)? optionTrailing;
  final bool enabled;
  final ValueChanged<bool>? onSavingChanged;

  /// 索引只包含选项，不包含页面顶部的其他设置行。
  final ReorderCallback? onReorder;
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
    // 在页面本身订阅主题。列表构建回调里的 context 属于 Sliver，
    // 仅在那里读取颜色，不会保证已经创建的选项随主题重新构建。
    final colors = context.gtColors;
    final offset = widget.leading == null ? 0 : 1;
    Widget item(BuildContext context, int index) {
      final Widget row;
      final Key key;
      if (index < offset) {
        key = const ValueKey('settings-leading');
        row = widget.leading!;
      } else {
        final option = widget.options[index - offset];
        key = ValueKey(option);
        final active = option == selected;
        row = GtListButton(
          selected: active,
          contentPadding: EdgeInsets.zero,
          minTileHeight: 48,
          title: Text(
            widget.label(option),
            style:
                widget.optionStyle?.call(option, active) ??
                GtText.body(active ? colors.actionPrimary : colors.textPrimary),
          ),
          trailing:
              widget.optionTrailing?.call(option, active) ??
              (active
                  ? GtIcon(GtIcons.check, size: 20, color: colors.actionPrimary)
                  : null),
          onPressed: _saving || !widget.enabled ? null : () => _select(option),
        );
      }
      return Column(
        key: key,
        children: [
          row,
          if (index < widget.options.length + offset - 1) const Divider(),
        ],
      );
    }

    return Scaffold(
      appBar: GtAppBar(title: Text(widget.title), actions: widget.actions),
      body: SafeArea(
        child: widget.onReorder != null
            ? ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
                itemCount: widget.options.length + offset,
                buildDefaultDragHandles: false,
                onReorderItem: (oldIndex, newIndex) {
                  if (!_saving && widget.enabled && oldIndex >= offset) {
                    widget.onReorder!(oldIndex - offset, newIndex - offset);
                  }
                },
                itemBuilder: item,
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
                itemCount: widget.options.length + offset,
                itemBuilder: item,
              ),
      ),
    );
  }

  Future<void> _select(T option) async {
    if (option == widget.selected(ref)) return;
    setState(() => _saving = true);
    widget.onSavingChanged?.call(true);
    try {
      await widget.save(ref, option);
    } catch (appError, appStack) {
      AppErrors.report(
        appError,
        appStack,
        operation: '设置未保存，请重试',
        notify: false,
      );
      if (mounted) {
        AppErrors.report(appError, appStack, operation: '设置未保存，请重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
      if (mounted) widget.onSavingChanged?.call(false);
    }
  }
}
