import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../platform/channels/preset_fonts.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';
import '../../../core/widgets/gt_list_button.dart';
import '../../../core/widgets/gt_button.dart';
import '../../settings/widgets/font_choices.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'listening_option_header.dart';
import 'reader_sheet.dart';
import 'reader_option_route.dart';
import 'reader_option_autosave.dart';
import 'reader_performance.dart';

/// 名单与字体先就绪，再替换设置面板；订阅覆盖弹层整个生命周期。
Future<void> showReaderFontSheet(
  BuildContext context,
  WidgetRef ref,
  String bookId, {
  required bool supportsOriginalFont,
}) async {
  final container = ProviderScope.containerOf(context);
  final vm = ref.read(readerProvider.notifier);
  final lease = container.listen(readerSettingsProvider(bookId), (_, _) {});
  try {
    final fonts = await measureReader(
      'font-sheet.catalog',
      () => container.read(fontFamilyNamesProvider.future),
    );
    final settings = await container.read(
      readerSettingsProvider(bookId).future,
    );
    if (!context.mounted) return;
    await measureReader('font-sheet.previews', () async {
      PresetFonts.preparePreviews();
    });
    if (!context.mounted) return;
    final choices = readingFontChoices(
      settings.fontSettings,
      fonts,
      supportsOriginalFont: supportsOriginalFont,
    );
    await showReaderOption<void>(
      context,
      ref,
      (context) => UncontrolledProviderScope(
        container: container,
        child: ReaderFontSheet(
          choices: choices,
          selected: selectedFontChoice(
            settings.fontSettings,
            supportsOriginalFont: supportsOriginalFont,
          ),
          save: container
              .read(readerSettingsProvider(bookId).notifier)
              .confirmFontChoice,
          fontWeight: settings.settings.fontWeight,
          saveFontWeight: (value) async {
            final settingsVm = container.read(
              readerSettingsProvider(bookId).notifier,
            );
            settingsVm.setFontWeight(value);
            await settingsVm.pendingWrites;
            return container
                    .read(readerSettingsProvider(bookId))
                    .requireValue
                    .settings
                    .fontWeight ==
                value;
          },
        ),
      ),
      bookId: bookId,
    );
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '打开字体列表失败');
    vm.showNotice('字体列表未能打开，请重试');
  } finally {
    lease.close();
  }
}

/// 点选即准备并应用字体；保存失败保留已成功应用的选项与正文。
class ReaderFontSheet extends StatefulWidget {
  const ReaderFontSheet({
    super.key,
    required this.choices,
    required this.selected,
    required this.save,
    required this.fontWeight,
    required this.saveFontWeight,
  });
  final Map<String, String> choices;
  final String selected;
  final Future<bool> Function(String) save;
  final int fontWeight;
  final Future<bool> Function(int) saveFontWeight;
  @override
  State<ReaderFontSheet> createState() => _ReaderFontSheetState();
}

class _ReaderFontSheetState extends State<ReaderFontSheet> {
  late String selected = widget.selected;
  late int fontWeight = widget.fontWeight;
  bool saving = false;

  Future<bool>? _pending;

  Future<bool> _choose(String choice) async {
    if (choice == selected) return true;
    setState(() => saving = true);
    try {
      final applied = await widget.save(choice);
      if (mounted && applied) setState(() => selected = choice);
      return applied;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<bool> _setFontWeight(int next) async {
    setState(() => saving = true);
    try {
      final applied = await widget.saveFontWeight(next);
      // 字体与字重都在准备、保存成功后显示新值，失败时保留上次生效状态。
      if (mounted && applied) setState(() => fontWeight = next);
      return applied;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _weightControl(BuildContext context) {
    final colors = context.gtColors;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GtButton(
        key: const Key('reader-font-weight-button'),
        style: GtButton.compactStyle.copyWith(
          foregroundColor: WidgetStatePropertyAll(colors.textPrimary),
          backgroundColor: WidgetStatePropertyAll(colors.subtle),
        ),
        onPressed: saving
            ? null
            : () {
                final next = switch (fontWeight) {
                  400 => 500,
                  500 => 700,
                  _ => 400,
                };
                _pending = _setFontWeight(next);
              },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GtIcon(GtIcons.cycle, size: 16, color: colors.textPrimary),
            const SizedBox(width: 4),
            Text(
              switch (fontWeight) {
                500 => '半粗',
                700 => '粗体',
                _ => '正常',
              },
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.values[fontWeight ~/ 100 - 1],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ReaderOptionAutosave(
    save: () async => await _pending ?? true,
    child: Scaffold(
      backgroundColor: ReaderSheet.backgroundOf(context),
      appBar: ListeningOptionHeader(
        // 窄屏、大系统字号时才缩放标题，避免与右侧按钮相互遮挡。
        title: const FittedBox(fit: BoxFit.scaleDown, child: Text('字体样式')),
        actions: [_weightControl(context)],
      ),
      body: SafeArea(
        top: false,
        child: ListView.separated(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: widget.choices.length,
          separatorBuilder: (_, _) => const Divider(),
          itemBuilder: (context, index) {
            final entry = widget.choices.entries.elementAt(index);
            final active = entry.key == selected;
            return GtListButton(
              selected: active,
              contentPadding: EdgeInsets.zero,
              minTileHeight: 48,
              title: Text(
                entry.value,
                style: fontChoiceStyle(context, entry.key, active),
              ),
              trailing: active
                  ? GtIcon(
                      GtIcons.check,
                      size: 20,
                      color: context.gtColors.actionPrimary,
                    )
                  : null,
              onPressed: saving
                  ? null
                  : () {
                      _pending = _choose(entry.key);
                    },
            );
          },
        ),
      ),
    ),
  );
}
