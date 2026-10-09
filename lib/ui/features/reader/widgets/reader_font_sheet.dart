import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../platform/channels/preset_fonts.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';
import '../../../core/widgets/gt_list_button.dart';
import '../../../core/widgets/gt_switch.dart';
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
          bold: settings.settings.bold,
          saveBold: (value) async {
            final settingsVm = container.read(
              readerSettingsProvider(bookId).notifier,
            );
            settingsVm.setBold(value);
            await settingsVm.pendingWrites;
            return container
                    .read(readerSettingsProvider(bookId))
                    .requireValue
                    .settings
                    .bold ==
                value;
          },
        ),
      ),
      bookId: bookId,
    );
  } catch (_) {
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
    required this.bold,
    required this.saveBold,
  });
  final Map<String, String> choices;
  final String selected;
  final Future<bool> Function(String) save;
  final bool bold;
  final Future<bool> Function(bool) saveBold;
  @override
  State<ReaderFontSheet> createState() => _ReaderFontSheetState();
}

class _ReaderFontSheetState extends State<ReaderFontSheet> {
  late String selected = widget.selected;
  late bool bold = widget.bold;
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

  Future<bool> _setBold(bool next) async {
    setState(() => saving = true);
    try {
      final applied = await widget.saveBold(next);
      // 字体与粗体都在准备、保存成功后显示新值，失败时保留上次生效状态。
      if (mounted && applied) setState(() => bold = next);
      return applied;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _boldControl(BuildContext context) {
    final colors = context.gtColors;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: MergeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '粗体',
              style: TextStyle(fontSize: 12, color: colors.textPrimary),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 48,
              child: GtSwitch(
                key: const Key('reader-bold-switch'),
                value: bold,
                scale: 0.65,
                onChanged: saving
                    ? null
                    : (value) {
                        _pending = _setBold(value);
                      },
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
        // 窄屏、大系统字号时才缩放标题，避免与右侧开关相互遮挡。
        title: const FittedBox(fit: BoxFit.scaleDown, child: Text('字体样式')),
        actions: [_boldControl(context)],
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
