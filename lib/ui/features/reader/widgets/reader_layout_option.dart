import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/reading_controls_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'reader_compact_option.dart';
import 'reader_option_autosave.dart';
import 'reader_option_route.dart';
import 'reader_turn_choices.dart';
import '../../settings/widgets/reading_controls_options.dart';
import '../../settings/widgets/settings_action.dart';

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
    if (turn) {
      final fixedView = (await container.read(readingControlsProvider.future))
          .pdfFixedViewMode;
      if (!context.mounted) return;
      await ReaderTurnChoices.prepare(
        context,
        effects: settings.freePdfView(fixedView: fixedView)
            ? PageTurnEffect.pdfFreeViewEffects
            : PageTurnEffect.values,
      );
    } else {
      await container.read(readingControlsReadyProvider.future);
    }
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

  PageTurnEffect _effective(PageTurnEffect effect, bool freePdf) =>
      freePdf ? effect.forPdfFreeView() : effect;

  Future<bool> _save() async {
    if (!widget.turn) return await _pending ?? true;
    final current = ref
        .read(readerSettingsProvider(widget.bookId))
        .requireValue;
    if (current.settings.spreadEnabled) return true;
    final freePdf = current.freePdfView(
      fixedView: ref.read(pdfFixedViewModeProvider),
    );
    final chosen = _effective(_effect, freePdf);
    // 只打开再收起面板时，保留其他阅读模式正在使用的翻页偏好。
    if (_effect == current.settings.pageTurnEffect ||
        chosen == current.settings.pageTurnEffect) {
      return true;
    }
    setState(() => _saving = true);
    try {
      final vm = ref.read(readerSettingsProvider(widget.bookId).notifier);
      vm.setPageTurnEffect(chosen);
      await vm.pendingWrites;
      final saved = ref
          .read(readerSettingsProvider(widget.bookId))
          .value!
          .settings;
      return saved.pageTurnEffect == chosen;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ReaderOptionAutosave(
    save: _save,
    child: ReaderCompactOption(
      title: widget.turn ? '翻页方式' : '更多设置',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: widget.turn ? _turnOptions() : _otherOptions(),
      ),
    ),
  );

  Widget _turnOptions() {
    final current = ref
        .watch(readerSettingsProvider(widget.bookId))
        .requireValue;
    final freePdf = current.freePdfView(
      fixedView: ref.watch(pdfFixedViewModeProvider),
    );
    final spread = current.settings.spreadEnabled;
    return ReaderTurnChoices(
      selected: spread ? PageTurnEffect.curl : _effective(_effect, freePdf),
      curlOnly: spread,
      effects: freePdf
          ? PageTurnEffect.pdfFreeViewEffects
          : PageTurnEffect.values,
      onSelect: (effect) {
        if (!_saving) setState(() => _effect = effect);
      },
    );
  }

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
      padding: EdgeInsets.zero,
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
          if (!current.layoutMode.isOriginal)
            _toggle(
              '图片查看',
              'reader-image-viewing-switch',
              ref.watch(readingControlsProvider).requireValue.imageViewing,
              (value) => saveSetting(
                context,
                () => ref
                    .read(readingControlsProvider.notifier)
                    .change(imageViewing: value),
              ),
            ),
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
          ReadingControlsOptions(
            includeKeepAwake: false,
            includePdfFixedViewMode: current.pdfMode,
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
  ) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
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
    ),
  );
}
