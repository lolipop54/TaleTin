import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../core/diagnostics/app_errors.dart';
import '../../../../domain/models/reading_background.dart';
import '../../../../platform/channels/system_toast.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/global_reading_settings.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../../../core/widgets/gt_icon.dart';
import '../../reader/view_models/reader_settings_view_model.dart';
import '../view_models/reading_backgrounds.dart';

/// 两处入口共用背景名单和操作，书内只隐藏导入按钮，不隐藏已导入的图片。
class ReadingBackgroundChoices extends ConsumerStatefulWidget {
  const ReadingBackgroundChoices({super.key, this.bookId});
  final String? bookId;
  @override
  ConsumerState<ReadingBackgroundChoices> createState() =>
      _ReadingBackgroundChoicesState();
}

class _ReadingBackgroundChoicesState
    extends ConsumerState<ReadingBackgroundChoices> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '阅读背景设置失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ReadingBackground item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.gtColors.surface,
        title: Text('删除${item.label}？'),
        actions: [
          GtDialogAction(
            label: '取消',
            onPressed: () => Navigator.pop(context, false),
          ),
          GtDialogAction(
            label: '删除',
            role: GtDialogActionRole.danger,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => ref.read(readingBackgroundsProvider.notifier).remove(item.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(readingBackgroundsProvider).value;
    if (catalog == null) return const SizedBox.shrink();
    final bookId = widget.bookId;
    final settings = bookId == null
        ? null
        : ref.watch(readerSettingsProvider(bookId)).value;
    final selected = bookId == null
        ? catalog.globalId
        : settings?.theme.backgroundId;
    final colors = context.gtColors;
    final globalThemeId = bookId == null
        ? ref.watch(globalSettingsProvider).value?.themeId
        : null;
    final solid =
        settings?.theme.background ??
        (ReadingTheme.values
                    .where((t) => t.name == globalThemeId)
                    .firstOrNull ??
                kDefaultReadingTheme)
            .background;
    final root = ref.watch(libraryRootPathProvider);
    return LayoutBuilder(
      builder: (context, box) {
        final width = bookId == null
            ? 80.0
            : ((box.maxWidth - 48) / 5).clamp(52.0, 80.0);
        Widget card({
          required Widget preview,
          required String label,
          required VoidCallback? onTap,
          VoidCallback? onLongPress,
          bool chosen = false,
          Key? key,
        }) => Padding(
          padding: const EdgeInsets.only(right: 12),
          child: SizedBox(
            width: width,
            child: GtButton.raw(
              key: key,
              onPressed: onTap,
              onLongPress: onLongPress,
              borderRadius: BorderRadius.circular(GtRadius.control),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: bookId == null ? 48 : 44,
                    decoration: BoxDecoration(
                      color: solid,
                      borderRadius: BorderRadius.circular(GtRadius.control),
                    ),
                    // 图片先按外轮廓裁切，边框最后绘制，避免方形缩略图盖住圆角。
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(GtRadius.control),
                      border: Border.all(
                        color: chosen
                            ? colors.actionPrimary
                            : colors.borderSubtle,
                        width: chosen ? 2 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        preview,
                        if (chosen)
                          Positioned(
                            right: 3,
                            bottom: 3,
                            child: GtIcon(
                              GtIcons.checkCircle,
                              size: 16,
                              color: colors.actionPrimary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: GtSpacing.s1),
                  Text(
                    label,
                    maxLines: 1,
                    style: GtText.caption(colors.textSecondary)
                        .copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        );
        final full = catalog.custom.length >= ReadingBackground.limit;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in catalog.all)
                card(
                  key: ValueKey('reading-background-${item.id}'),
                  label: item.label,
                  chosen: item.id == selected,
                  preview: item.asset == null && item.path == null
                      ? const SizedBox.expand()
                      : Image(
                          image: backgroundThumbnail(item, root),
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                  onTap: _busy
                      ? null
                      : () => _run(
                          () => bookId == null
                              ? ref
                                    .read(readingBackgroundsProvider.notifier)
                                    .selectGlobal(item.id)
                              : ref
                                    .read(
                                      readerSettingsProvider(bookId).notifier,
                                    )
                                    .setBackground(item.id),
                        ),
                  onLongPress: !_busy && item.custom
                      ? () => _delete(item)
                      : null,
                ),
              if (bookId == null)
                card(
                  key: const Key('reading-background-add'),
                  label: '',
                  preview: Icon(
                    Icons.add,
                    color: full || _busy
                        ? colors.textMuted
                        : colors.textPrimary,
                    size: 24,
                  ),
                  onTap: _busy
                      ? null
                      : () {
                          if (full) {
                            SystemToast.show('已达到导入上限，长按删除其一后可继续添加');
                          } else {
                            _run(
                              () => ref
                                  .read(readingBackgroundsProvider.notifier)
                                  .import(),
                            );
                          }
                        },
                ),
            ],
          ),
        );
      },
    );
  }
}
