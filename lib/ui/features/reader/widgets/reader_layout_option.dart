import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/reading_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'reader_compact_option.dart';
import 'reader_option_autosave.dart';
import 'reader_option_route.dart';
import 'reader_turn_choices.dart';

Future<void> showReaderLayoutOption(
  BuildContext context,
  WidgetRef ref,
  String bookId, {
  required bool turn,
}) async {
  final container = ProviderScope.containerOf(context);
  final lease = container.listen(readerSettingsProvider(bookId), (_, _) {});
  try {
    final settings = await container.read(
      readerSettingsProvider(bookId).future,
    );
    if (!context.mounted) return;
    // 卡片图片解码完成后才换层，不在新面板打开后逐张补图。
    if (turn) await ReaderTurnChoices.prepare(context);
    if (!context.mounted) return;
    await showReaderOption<void>(
      context,
      ref,
      (_) => ReaderLayoutOption(
        bookId: bookId,
        initial: settings.settings,
        turn: turn,
      ),
      bookId: bookId,
      shrinkWrap: true,
    );
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '打开排版选项失败');
    container.read(readerProvider.notifier).showNotice('设置选项未能打开，请重试');
  } finally {
    lease.close();
  }
}

/// 翻页收起时保存；首行缩进点击后就保存并应用，不必等待面板收起。
class ReaderLayoutOption extends ConsumerStatefulWidget {
  const ReaderLayoutOption({
    super.key,
    required this.bookId,
    required this.initial,
    required this.turn,
  });
  final String bookId;
  final ReadingSettings initial;
  final bool turn;
  @override
  ConsumerState<ReaderLayoutOption> createState() => _LayoutOptionState();
}

class _LayoutOptionState extends ConsumerState<ReaderLayoutOption> {
  late PageTurnEffect _effect = widget.initial.pageTurnEffect;
  bool _saving = false;
  Future<bool>? _pending;

  Future<bool> _save() async {
    if (ref
            .read(readerSettingsProvider(widget.bookId))
            .value
            ?.settings
            .spreadEnabled ==
        true) {
      return true;
    }
    if (!widget.turn) return await _pending ?? true;
    setState(() => _saving = true);
    try {
      final vm = ref.read(readerSettingsProvider(widget.bookId).notifier);
      final previous = ref
          .read(readerSettingsProvider(widget.bookId))
          .value!
          .settings;
      if (_effect != previous.pageTurnEffect) vm.setPageTurnEffect(_effect);
      await vm.pendingWrites;
      final saved = ref
          .read(readerSettingsProvider(widget.bookId))
          .value!
          .settings;
      return saved.pageTurnEffect == _effect;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ReaderOptionAutosave(
    save: _save,
    child: ReaderCompactOption(
      title: widget.turn ? '翻页方式' : '其他设置',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: widget.turn
            ? ReaderTurnChoices(
                selected:
                    ref
                            .watch(readerSettingsProvider(widget.bookId))
                            .value
                            ?.settings
                            .spreadEnabled ==
                        true
                    ? PageTurnEffect.curl
                    : _effect,
                curlOnly:
                    ref
                        .watch(readerSettingsProvider(widget.bookId))
                        .value
                        ?.settings
                        .spreadEnabled ==
                    true,
                onSelect: (effect) {
                  if (!_saving) setState(() => _effect = effect);
                },
              )
            : _otherOptions(),
      ),
    ),
  );

  Widget _otherOptions() {
    final current = ref
        .watch(readerSettingsProvider(widget.bookId))
        .requireValue;
    final saved = current.fontSettings;
    final vm = ref.read(readerSettingsProvider(widget.bookId).notifier);
    Widget option(
      String label,
      String key,
      bool value,
      ValueChanged<bool> set,
    ) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _toggle(label, key, value, (next) {
        set(next);
        _pending = vm.pendingWrites.then((_) => true);
      }),
    );
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!current.pdfMode)
            option('首行缩进', 'reader-indent-switch', saved.indent, vm.setIndent),
          if (!current.pdfMode)
            option(
              '书边效果',
              'reader-book-edges-switch',
              saved.bookEdges,
              vm.setBookEdges,
            ),
          option(
            '横屏',
            'reader-landscape-switch',
            saved.landscape,
            vm.setLandscape,
          ),
          if (!current.pdfMode)
            option(
              '横屏双翻页',
              'reader-landscape-spread-switch',
              saved.landscapeSpread,
              vm.setLandscapeSpread,
            ),
        ],
      ),
    );
  }

  Widget _toggle(
    String label,
    String key,
    bool value,
    ValueChanged<bool> onChange,
  ) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GtText.body(context.gtColors.textPrimary)
              .copyWith(fontSize: 14),
        ),
      ),
      GtSwitch(
        key: Key(key),
        value: value,
        onChanged: _saving ? null : onChange,
      ),
    ],
  );
}
