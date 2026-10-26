import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../../platform/channels/reading_fonts.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/reading_settings.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'reader_sheet.dart';
import 'reader_font_sheet.dart';
import 'reader_font_controls.dart';
import 'reader_layout_option.dart';
import '../../settings/widgets/settings_slider.dart';
import '../../../core/widgets/gt_icon.dart';

/// 字体与排版面板（参考图 03-3）。
/// 排版模式、字号/字体、排版滑条，以及翻页方式／其他设置的二级入口。
///
/// 每一项写进本书覆盖：二级面板收起后、滑条松手后保存；
/// 重排仍停在原句子上，
/// 退出应用再进来仍然是这套设置；面板不再提供恢复全局入口。
///
/// EPUB／MOBI／AZW3 有「简化 / 原书」两选。两种模式都能调整行高、
/// 段落间距；首行缩进可保留或关闭，图片段落始终不缩进。
/// 字号、页边距与阅读主题仍然生效（设计文档 2.4）。
class PanelTypography extends ConsumerWidget {
  const PanelTypography({super.key, required this.bookId, this.bookFormat});

  final String bookId;

  /// 本书格式；null 表示还没读出来（不显示排版模式开关）
  final BookFormat? bookFormat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider(bookId)).value;
    // 设置还没读出来时不画面板：正常不会出现（要等设置到位才会排正文）
    if (settings == null) return const SizedBox.shrink();

    final vm = ref.read(readerSettingsProvider(bookId).notifier);
    final colors = context.gtColors;
    // 这里只显示当前字体名称，打开字体选择页才准备整份名单与预览。
    final fontNames = ReadingFonts.loadedNames;
    // 原书排版只对 EPUB 开放；TXT 没有原书样式，不出现这个开关
    final showLayoutMode = bookFormat?.supportsOriginalLayout == true;
    final pdf = bookFormat == BookFormat.pdf;
    if (pdf && settings.settings.layoutMode.isOriginal) {
      return ReaderSheet(
        title: '设置',
        onClose: () => ref.read(readerProvider.notifier).closePanel(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: GtSpacing.s5,
            vertical: GtSpacing.s3,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel(context, '排版模式'),
              const SizedBox(height: GtSpacing.s2),
              _modeRow(context, ref, settings),
              const SizedBox(height: GtSpacing.s4),
              _optionRow(context, ref, settings),
            ],
          ),
        ),
      );
    }

    return ReaderSheet(
      title: '设置',
      onClose: () => ref.read(readerProvider.notifier).closePanel(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: GtSpacing.s2),
            if (showLayoutMode) ...[
              _sectionLabel(context, '排版模式'),
              const SizedBox(height: GtSpacing.s2),
              _modeRow(context, ref, settings),
              const SizedBox(height: GtSpacing.s5),
              Container(height: 1, color: colors.borderSubtle),
              const SizedBox(height: GtSpacing.s2),
            ],
            ReaderFontControls(
              settings: settings.fontSettings,
              fontNames: fontNames,
              // TXT 没有书内字体，旧的原书排版设置也不能显示该选项。
              supportsOriginalFont: showLayoutMode && !pdf,
              onSize: vm.setFontSize,
              onFont: () => showReaderFontSheet(
                context,
                ref,
                bookId,
                supportsOriginalFont: showLayoutMode && !pdf,
              ),
            ),
            const SizedBox(height: GtSpacing.s0),
            _sliderRow(
              context,
              ref,
              label: '行高',
              value: settings.settings.lineHeight,
              min: 1.2,
              max: 2.2,
              divisions: 10,
              format: (v) => v.toStringAsFixed(1),
              onChanged: vm.setLineHeight,
            ),
            const SizedBox(height: GtSpacing.s2),
            _sliderRow(
              context,
              ref,
              label: '段落间距',
              value: settings.paragraphGapPx,
              min: 0,
              max: 30,
              divisions: 30,
              format: (v) => v.round().toString(),
              onChanged: vm.setParagraphGap,
            ),
            const SizedBox(height: GtSpacing.s2),
            _sliderRow(
              context,
              ref,
              label: '页边距',
              value: settings.settings.horizontalPadding,
              min: 16,
              max: 40,
              divisions: 24,
              format: (v) => v.round().toString(),
              onChanged: vm.setPagePadding,
            ),
            const SizedBox(height: GtSpacing.s2),
            _optionRow(context, ref, settings),
            const SizedBox(height: GtSpacing.s2),
          ],
        ),
      ),
    );
  }

  Widget _optionRow(
    BuildContext context,
    WidgetRef ref,
    ReaderSettingsState settings,
  ) => Row(
    children: [
      Expanded(
        child: _optionButton(
          context,
          settings.settings.pageTurnEffect.label,
          '翻页方式',
          () => showReaderLayoutOption(context, ref, bookId, turn: true),
        ),
      ),
      const SizedBox(width: GtSpacing.s3),
      Expanded(
        child: _optionButton(
          context,
          '其他设置',
          '其他设置',
          () => showReaderLayoutOption(context, ref, bookId, turn: false),
        ),
      ),
    ],
  );

  /// 两个浅色胶囊共用一行，翻页入口直接显示当前方式；箭头提示还有下一层。
  Widget _optionButton(
    BuildContext context,
    String label,
    String title,
    VoidCallback onTap,
  ) => GtButton.raw(
    key: ValueKey('reader-option-$title'),
    tooltip: title,
    borderRadius: BorderRadius.circular(24),
    onPressed: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: context.gtColors.subtle,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GtText.body(context.gtColors.textPrimary)
                  .copyWith(fontSize: 13),
            ),
          ),
          const SizedBox(width: 4),
          GtIcon(
            GtIcons.chevronRight,
            size: 16,
            color: context.gtColors.textSecondary,
          ),
        ],
      ),
    ),
  );

  /// 排版模式两选：简化排版 / 原书排版。
  Widget _modeRow(
    BuildContext context,
    WidgetRef ref,
    ReaderSettingsState settings,
  ) {
    final vm = ref.read(readerSettingsProvider(bookId).notifier);
    final colors = context.gtColors;
    final current = settings.settings.layoutMode;
    return Row(
      children: [
        for (final (mode, label, hint) in [
          (
            ReadingLayoutMode.simplified,
            bookFormat == BookFormat.pdf ? '电子书模式' : '简化排版',
            '阅读器排版',
          ),
          (
            ReadingLayoutMode.original,
            bookFormat == BookFormat.pdf ? 'PDF模式' : '原书排版',
            '还原原书样式',
          ),
        ]) ...[
          if (mode == ReadingLayoutMode.original)
            const SizedBox(width: GtSpacing.s3),
          Expanded(
            child: GtButton.raw(
              borderRadius: BorderRadius.circular(GtRadius.control),
              onPressed: () => vm.setLayoutMode(mode),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: GtSpacing.s2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(GtRadius.control),
                  border: Border.all(
                    width: current == mode ? 2 : 1,
                    color: current == mode
                        ? colors.actionPrimary
                        : colors.borderSubtle,
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      label,
                      style: GtText.body(
                        current == mode
                            ? colors.actionPrimary
                            : colors.textPrimary,
                      ).copyWith(fontSize: 15),
                    ),
                    if (bookFormat != BookFormat.pdf) const SizedBox(height: 2),
                    if (bookFormat != BookFormat.pdf)
                      Text(
                        hint,
                        style: GtText.caption(colors.textMuted)
                            .copyWith(fontSize: 11),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final colors = context.gtColors;
    return Text(
      text,
      style: GtText.body(colors.textSecondary).copyWith(fontSize: 14),
    );
  }

  Widget _sliderRow(
    BuildContext context,
    WidgetRef ref, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: SettingsSlider(
        labelStyle: GtText.body(context.gtColors.textPrimary)
            .copyWith(fontSize: 14),
        numberStyle: TextStyle(
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          fontSize: 10,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: enabled
              ? context.gtColors.textPrimary
              : context.gtColors.textMuted,
        ),
        thumbRadius: GtSliderSize.thumbRadiusSmall,
        trackThickness: GtSliderSize.trackThicknessSmall,
        label: label,
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        format: format,
        backgroundColor: ReaderSheet.backgroundOf(context),
        save: enabled
            ? (value) async {
                onChanged(value);
                // 保留手柄的临时值，等本书设置真正保存并发布后再撤掉。
                await ref
                    .read(readerSettingsProvider(bookId).notifier)
                    .pendingWrites;
              }
            : null,
      ),
    );
  }
}
