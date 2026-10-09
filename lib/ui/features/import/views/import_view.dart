import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/import_job.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/decorations.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/import_view_model.dart';
import '../widgets/encoding_sheet.dart';
import '../../../../domain/services/document_platform.dart';
import '../view_models/local_files_view_model.dart';
import 'local_files_view.dart';

/// 导入书籍页（参考图 06）：
/// 返回 + 标题 → 选择文件卡片 → 已选文件队列 → 隐私说明。
///
/// 队列状态与真实导入流水线一一对应：等待 / 复制 / 解析 / 完成 / 重复 /
/// 失败（可重试）/ 已取消。
class ImportView extends ConsumerWidget {
  const ImportView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final state = ref.watch(importProvider);

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, colors),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      GtSpacing.s5,
                      0,
                      GtSpacing.s5,
                      GtSpacing.s8,
                    ),
                    children: [
                      const SizedBox(height: GtSpacing.s5),
                      const _PickCard(),
                      const SizedBox(height: GtSpacing.s5),
                      if (state.items.isNotEmpty) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                state.summary,
                                style: GtText.sectionTitle(colors.textPrimary)
                                    .copyWith(fontSize: 17),
                              ),
                            ),
                            if (state.items.any((i) => i.stage.isFinished) &&
                                !state.running)
                              GtButton(
                                onPressed: () => ref
                                    .read(importProvider.notifier)
                                    .clearFinished(),
                                child: const Text('清空已结束'),
                              ),
                          ],
                        ),
                        const SizedBox(height: GtSpacing.s1),
                        for (final item in state.items) _ImportRow(item: item),
                      ] else
                        _EmptyQueueHint(colors: colors),
                      const SizedBox(height: GtSpacing.s12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GtIcon(
                            GtIcons.lock,
                            size: 14,
                            color: colors.textMuted,
                          ),
                          const SizedBox(width: GtSpacing.s1),
                          Flexible(
                            child: Text(
                              '文件将复制到应用私有目录，仅在本机保存。',
                              style: GtText.caption(colors.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // 右上角垂下的蓝色书签带
            const Positioned(top: 0, right: 28, child: RibbonBookmark()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, GtColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        GtSpacing.s2,
        GtSpacing.s2,
        GtSpacing.s5,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GtButton.icon(
                onPressed: () => context.pop(),
                icon: GtIcon(
                  GtIcons.arrowBack,
                  size: 20,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: GtSpacing.s2),
              Text('导入书籍', style: GtText.pageTitle(colors.textPrimary)),
            ],
          ),
        ],
      ),
    );
  }
}

/// 队列为空时的说明。
class _EmptyQueueHint extends StatelessWidget {
  const _EmptyQueueHint({required this.colors});

  final GtColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: GtSpacing.s6),
      child: Column(
        children: [
          GtIcon(GtIcons.folderPlus, size: 36, color: colors.textMuted),
          const SizedBox(height: GtSpacing.s2),
          Text('还没有选择文件', style: GtText.body(colors.textMuted)),
        ],
      ),
    );
  }
}

/// 「选择本地文件」卡片：标题 + 格式说明 + 主按钮。
class _PickCard extends ConsumerStatefulWidget {
  const _PickCard();

  @override
  ConsumerState<_PickCard> createState() => _PickCardState();
}

class _PickCardState extends ConsumerState<_PickCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(GtSpacing.s6),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(GtRadius.card),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('选择本地文件', style: GtText.pageTitle(colors.textPrimary)),
          const SizedBox(height: GtSpacing.s2),
          Text('支持 EPUB · TXT / 可多选', style: GtText.body(colors.textMuted)),
          const SizedBox(height: GtSpacing.s6),
          SizedBox(
            width: double.infinity,
            height: GtSize.touchMin,
            child: GtButton.filled(
              onPressed: _busy ? null : _pick,
              style: FilledButton.styleFrom(
                backgroundColor: colors.actionPrimary,
                foregroundColor: colors.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(GtRadius.control),
                ),
                textStyle: GtText.body(colors.onPrimary)
                    .copyWith(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              child: Text(_busy ? '正在选择…' : '选择本地文件'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick() async {
    final vm = ref.read(importProvider.notifier);
    setState(() => _busy = true);
    try {
      final documents = await Navigator.of(context).push<List<PickedDocument>>(
        MaterialPageRoute(builder: (_) => ProviderScope(
          overrides: [localFilesProvider.overrideWith(LocalFilesViewModel.new)],
          child: const LocalFilesView(selectionOnly: true),
        )),
      );
      if (documents == null || documents.isEmpty || !mounted) return;
      final needConfirm = await vm.pick(documents: documents);
      if (!mounted) return;
      final uris = documents.map((document) => document.uri).toSet();
      final selected = ref.read(importProvider).items
          .where((item) => uris.contains(item.key)).toList();
      if (needConfirm.isEmpty) {
        // 无需确认编码：直接开始导入
        vm.start(selected, const {});
        return;
      }
      final choices = await EncodingSheet.show(
        context,
        items: needConfirm,
        preparation: ref.read(textPreparationProvider),
      );
      if (choices == null) return;
      vm.start(selected, choices);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 队列条目：文件图标 + 名称/大小 + 状态区。
class _ImportRow extends ConsumerWidget {
  const _ImportRow({required this.item});

  final ImportItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final vm = ref.read(importProvider.notifier);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: GtSpacing.s4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FileTypeIcon(name: item.document.name),
          const SizedBox(width: GtSpacing.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.document.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GtText.bookTitle(colors.textPrimary)
                      .copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: GtSpacing.s1),
                _buildSubtitle(colors),
                if (item.isTxt && item.charset != null) ...[
                  const SizedBox(height: GtSpacing.s1),
                  _EncodingChip(item: item),
                ],
                if (item.failure != null) ...[
                  const SizedBox(height: GtSpacing.s1),
                  Row(
                    children: [
                      GtIcon(
                        GtIcons.alertCircle,
                        size: 15,
                        color: colors.danger,
                      ),
                      const SizedBox(width: GtSpacing.s1),
                      Expanded(
                        child: Text(
                          '导入失败 · ${item.failure!.displayText}',
                          style: GtText.caption(colors.danger)
                              .copyWith(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
                if (item.note != null && item.failure == null) ...[
                  const SizedBox(height: GtSpacing.s1),
                  Text(
                    item.note!,
                    style: GtText.caption(colors.textMuted)
                        .copyWith(fontSize: 12.5),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: GtSpacing.s3),
          _buildStatus(context, colors, vm),
        ],
      ),
    );
  }

  /// 副信息：进行中显示进度条，其余显示体积与阶段说明。
  Widget _buildSubtitle(GtColors colors) {
    if (item.stage == ImportStage.copying) {
      return Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(GtRadius.pill),
              child: LinearProgressIndicator(
                value: item.copyFraction,
                minHeight: 5,
                backgroundColor: colors.subtle,
                color: colors.actionPrimary,
              ),
            ),
          ),
          const SizedBox(width: GtSpacing.s2),
          Text(
            item.copyFraction == null
                ? '复制中'
                : '${(item.copyFraction! * 100).round()}%',
            style: GtText.caption(colors.textSecondary),
          ),
        ],
      );
    }
    if (item.stage == ImportStage.parsing) {
      return Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(GtRadius.pill),
              child: LinearProgressIndicator(
                value: item.parseFraction,
                minHeight: 5,
                backgroundColor: colors.subtle,
                color: colors.actionPrimary,
              ),
            ),
          ),
          const SizedBox(width: GtSpacing.s2),
          Text(
            item.parseFraction == null
                ? '解析中'
                : '解析 ${(item.parseFraction! * 100).round()}%',
            style: GtText.caption(colors.textSecondary),
          ),
        ],
      );
    }
    if (item.stage == ImportStage.committing) {
      return Text(
        '正在入库…',
        style: GtText.caption(colors.textSecondary).copyWith(fontSize: 13),
      );
    }
    return Text(
      item.sizeLabel,
      style: GtText.caption(colors.textMuted).copyWith(fontSize: 13),
    );
  }

  /// 右侧状态：已完成 / 取消 / 重试 / 打开。
  Widget _buildStatus(
    BuildContext context,
    GtColors colors,
    ImportViewModel vm,
  ) {
    switch (item.stage) {
      case ImportStage.done:
        return _statusLabel(
          colors,
          '已完成',
          colors.actionPrimary,
          icon: GtIcons.check,
        );
      case ImportStage.duplicate:
        return GtButton.raw(
          onPressed: () => context.pop(),
          child: Padding(
            padding: const EdgeInsets.all(GtSpacing.s1),
            child: Text(
              '已在书架',
              style: GtText.caption(colors.actionPrimary)
                  .copyWith(fontSize: 14),
            ),
          ),
        );
      case ImportStage.cancelled:
        // 取消后条目会立刻从队列移除，这里只是兜底：没有可操作内容
        return const SizedBox.shrink();
      case ImportStage.failed:
        return GtButton.raw(
          onPressed: () => vm.retry(item.key),
          child: Padding(
            padding: const EdgeInsets.all(GtSpacing.s1),
            child: Text(
              '重试',
              style: GtText.caption(colors.actionPrimary)
                  .copyWith(fontSize: 14),
            ),
          ),
        );
      case ImportStage.waiting:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '等待中',
              style: GtText.caption(colors.textMuted).copyWith(fontSize: 13),
            ),
            const SizedBox(width: GtSpacing.s1),
            _cancelButton(colors, vm),
          ],
        );
      case ImportStage.copying:
      case ImportStage.parsing:
      case ImportStage.committing:
        return _cancelButton(colors, vm);
    }
  }

  Widget _cancelButton(GtColors colors, ImportViewModel vm) => GtButton.raw(
    onPressed: () => vm.cancel(item.key),
    child: Padding(
      padding: const EdgeInsets.all(GtSpacing.s1),
      child: Text(
        '取消',
        style: GtText.caption(colors.actionPrimary).copyWith(fontSize: 14),
      ),
    ),
  );

  Widget _statusLabel(
    GtColors colors,
    String text,
    Color color, {
    required String icon,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 10,
          backgroundColor: color,
          child: GtIcon(icon, size: 14, color: colors.onPrimary),
        ),
        const SizedBox(width: GtSpacing.s1),
        Text(
          text,
          style: GtText.caption(color)
              .copyWith(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

/// TXT 条目的编码入口：点开可预览并切换编码，然后重新导入。
class _EncodingChip extends ConsumerWidget {
  const _EncodingChip({required this.item});

  final ImportItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final label = item.charsetConfident
        ? '编码 ${item.charset}'
        : '编码 ${item.charset}（待确认）';
    return GtButton.raw(
      onPressed: () async {
        final choices = await EncodingSheet.show(
          context,
          items: [item],
          preparation: ref.read(textPreparationProvider),
        );
        final choice = choices?[item.key];
        if (choice == null) return;
        ref.read(importProvider.notifier).startRetryWithChoice(item, choice);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GtIcon(
              GtIcons.documentText,
              size: 14,
              color: item.charsetConfident
                  ? colors.textMuted
                  : colors.actionPrimary,
            ),
            const SizedBox(width: GtSpacing.s1),
            Text(
              label,
              style: GtText.caption(
                item.charsetConfident ? colors.textMuted : colors.actionPrimary,
              ).copyWith(fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件类型图标：右上带折角的纸张 + 格式名（参考图 06）。
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.name});

  final String name;

  String get _ext {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? 'FILE' : name.substring(dot + 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return SizedBox(
      width: 52,
      height: 62,
      child: CustomPaint(
        painter: _FileSheetPainter(
          fill: colors.subtle,
          fold: colors.borderSubtle,
        ),
        child: Center(
          child: Text(
            _ext,
            style: GtText.caption(colors.textSecondary)
                .copyWith(fontSize: 11, letterSpacing: 1),
          ),
        ),
      ),
    );
  }
}

class _FileSheetPainter extends CustomPainter {
  _FileSheetPainter({required this.fill, required this.fold});

  final Color fill;
  final Color fold;

  @override
  void paint(Canvas canvas, Size size) {
    const foldSize = 14.0;
    final w = size.width;
    final h = size.height;
    final r = 10.0;
    // 纸张主体：右上角斜切
    final sheet = Path()
      ..moveTo(r, 0)
      ..lineTo(w - foldSize, 0)
      ..lineTo(w, foldSize)
      ..lineTo(w, h - r)
      ..quadraticBezierTo(w, h, w - r, h)
      ..lineTo(r, h)
      ..quadraticBezierTo(0, h, 0, h - r)
      ..lineTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..close();
    canvas.drawPath(sheet, Paint()..color = fill);
    // 折角
    final corner = Path()
      ..moveTo(w - foldSize, 0)
      ..lineTo(w - foldSize, foldSize)
      ..lineTo(w, foldSize)
      ..close();
    canvas.drawPath(corner, Paint()..color = fold);
  }

  @override
  bool shouldRepaint(_FileSheetPainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.fold != fold;
}
