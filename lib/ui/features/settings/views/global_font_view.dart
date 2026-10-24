import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../app/di/imported_font_providers.dart';
import '../../../../platform/channels/reading_fonts.dart';
import '../../../../domain/services/local_book_files.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';
import '../../reader/view_models/reader_settings_view_model.dart';
import '../../import/views/local_files_view.dart';
import '../../../../domain/models/reading_settings.dart';
import '../widgets/font_choices.dart';
import '../view_models/global_reading_settings.dart';
import '../widgets/settings_page.dart';
import '../widgets/settings_row.dart';

// 两个文字按钮相邻，文字间距为左右内边距之和；调小此值即可进一步收紧。
const _headerActionHorizontalPadding = 6.0;
// 返回区默认宽56dp，24dp图标居中，两侧各16dp；右侧文字沿用同一边距。
const _headerContentEdgeInset = 16.0;
// 删除与排序各占一格，图标居中；调小格宽即可缩小两图标间距。
const _fontActionWidth = 40.0;
const _headerActionStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, 48)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(
      horizontal: _headerActionHorizontalPadding,
      vertical: 8,
    ),
  ),
);
const _fontActionStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(_fontActionWidth, 48)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
);

/// 原书字体只在原书模式下参与选择；旧字体别名沿用正文的解析规则。
String globalFontChoice(ReadingSettings settings) =>
    selectedFontChoice(settings);

/// 进入前已经加载字体文件和名称；纵向列表随名称长度增高，不截断预览。
class GlobalFontView extends ConsumerStatefulWidget {
  const GlobalFontView({super.key});

  @override
  ConsumerState<GlobalFontView> createState() => _GlobalFontViewState();
}

class _GlobalFontViewState extends ConsumerState<GlobalFontView> {
  bool _editing = false;
  bool _busy = false;
  List<String>? _previewOrder;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(globalSettingsProvider).requireValue.typography;
    final fonts = ref.watch(fontFamilyNamesProvider).requireValue;
    final choices = readingFontChoices(
      settings,
      fonts,
      order: _previewOrder ?? ref.watch(fontOrderProvider).value ?? const [],
    );
    final ids = choices.keys.toList();
    return PopScope(
      canPop: !_editing && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) setState(() => _editing = false);
      },
      child: SettingsChoices<String>(
        title: '字体',
        enabled: !_busy,
        onSavingChanged: (value) => setState(() => _busy = value),
        onReorder: (oldIndex, newIndex) => _reorder(ids, oldIndex, newIndex),
        actions: [
          GtButton(
            style: _headerActionStyle,
            onPressed: _busy
                ? null
                : () => setState(() => _editing = !_editing),
            child: Text(_editing ? '完成' : '编辑'),
          ),
          GtButton(
            style: _headerActionStyle,
            onPressed: _busy
                ? null
                : () => Navigator.of(context, rootNavigator: true).push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const LocalFilesView(purpose: LocalFilePurpose.fonts),
                    ),
                  ),
            child: const Text('导入'),
          ),
          // 按钮已有6dp右内边距，只补足剩余10dp，不拉大编辑与导入的间隔。
          const SizedBox(
            width: _headerContentEdgeInset - _headerActionHorizontalPadding,
          ),
        ],
        leading: SettingsRow(
          label: '仅阅读页应用',
          trailing: GtSwitch(
            value: settings.fontOnlyInReader,
            onChanged: _busy
                ? null
                : (value) async {
                    try {
                      await ref
                          .read(globalSettingsProvider.notifier)
                          .change(
                            (current) =>
                                current.copyWith(fontOnlyInReader: value),
                          );
                    } catch (appError, appStack) {
                      AppErrors.report(
                        appError,
                        appStack,
                        operation: '全局字体未保存',
                        notify: false,
                      );
                      if (context.mounted) {
                        AppErrors.report(
                          appError,
                          appStack,
                          operation: '全局字体未保存',
                        );
                      }
                    }
                  },
          ),
        ),
        options: choices.keys.toList(),
        label: (id) => choices[id]!,
        optionStyle: (id, active) => fontChoiceStyle(context, id, active),
        optionTrailing: (id, _) => _editing
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (id.startsWith('gt-import-'))
                    GtButton.icon(
                      style: _fontActionStyle,
                      tooltip: '删除${choices[id]}',
                      onPressed: _busy ? null : () => _delete(id),
                      icon: const GtIcon(
                        GtIcons.trash,
                        size: 20,
                        color: GtPalette.danger,
                      ),
                    ),
                  // 紧凑横向间距仍保留48dp高度；固定项不允许发起拖动。
                  ReorderableDelayedDragStartListener(
                    key: ValueKey('font-reorder-$id'),
                    index: ids.indexOf(id) + 1,
                    enabled: !_busy && id != '__original' && id != 'sans-serif',
                    child: Semantics(
                      label: '排序${choices[id]}',
                      enabled:
                          !_busy && id != '__original' && id != 'sans-serif',
                      child: SizedBox(
                        width: _fontActionWidth,
                        height: 48,
                        child: Center(
                          child: GtIcon(
                            GtIcons.reorder,
                            size: 20,
                            color: id == '__original' || id == 'sans-serif'
                                ? Theme.of(context).disabledColor
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : null,
        selected: (ref) => globalFontChoice(
          ref.watch(globalSettingsProvider).requireValue.typography,
        ),
        save: (ref, id) async {
          if (id != '__original') {
            await ref.read(selectedFontLoaderProvider)(id);
          }
          await ref
              .read(globalSettingsProvider.notifier)
              .change(
                (current) => id == '__original'
                    ? current.copyWith(useOriginalFont: true)
                    : current.copyWith(fontFamily: id, useOriginalFont: false),
              );
        },
      ),
    );
  }

  Future<void> _delete(String id) async {
    setState(() => _busy = true);
    try {
      // 先准备回退字体并保存选择，再删文件；不改字号、字重或原书字体开关。
      await ref.read(selectedFontLoaderProvider)('sans-serif');
      await ref
          .read(importedFontStoreProvider)
          .removeFamily(
            id,
            beforeRemove: () =>
                ref.read(globalSettingsProvider.notifier).resetFontFamily(id),
          );
      await ReadingFonts.refreshImported();
      if (!mounted) return;
      ref.invalidate(fontFamilyNamesProvider);
      ref.invalidate(fontOrderProvider);
      ref.invalidate(currentTypographyFontsProvider);
      ref.invalidate(readerSettingsProvider);
      // FutureProvider刷新保留旧名单，准备完成后整页才显示新结果。
      await ref.read(fontFamilyNamesProvider.future);
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '删除字体失败，请重试', notify: mounted);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reorder(List<String> ids, int oldIndex, int newIndex) async {
    if (!_editing ||
        _busy ||
        ids[oldIndex] == '__original' ||
        ids[oldIndex] == 'sans-serif') {
      return;
    }
    final fixedCount = ids.contains('__original') ? 2 : 1;
    newIndex = newIndex.clamp(fixedCount, ids.length - 1);
    if (oldIndex == newIndex) return;
    final next = [...ids]..removeAt(oldIndex);
    next.insert(newIndex, ids[oldIndex]);
    setState(() {
      _previewOrder = next;
      _busy = true;
    });
    try {
      await ref.read(readingSettingsRepositoryProvider).saveFontOrder(next);
      if (!mounted) return;
      ref.invalidate(fontOrderProvider);
      await ref.read(fontOrderProvider.future);
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '字体顺序未保存，请重试', notify: mounted);
    } finally {
      if (mounted) {
        setState(() {
          _previewOrder = null;
          _busy = false;
        });
      }
    }
  }
}
