/// 选中文字后的操作菜单（实现计划 S3）。
///
/// 贴着选文摆：优先放在选区下方，下方空间不够就放到上方。
/// 这段选文还没有标注时是「高亮 / 写想法」；已经有标注时是「颜色 / 编辑想法 / 删除」。
/// 点「颜色」就地展开色板（黄 / 蓝 / 绿 / 无底色），选一下直接改那条标注，
/// 不重新弹一层菜单。
///
/// 保存成功才收起选区；点正文空白处或按返回键都会先收起选区（设计文档 4.1）。
library;
import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../engine/selection/selection_range.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_view_model.dart';

/// 菜单与选区之间的间距：要留得下手柄（竖线 + 圆点），
/// 不然菜单会盖住页末那一行的手柄，手柄就点不到了
const double kSelectionMenuGap = 40;

/// 一行菜单的高度（用于判断摆上方还是下方）
const double kSelectionMenuHeight = 44;

/// 色板一行的高度
const double kSelectionColorRowHeight = 44;

class SelectionActions extends ConsumerStatefulWidget {
  const SelectionActions({
    super.key,
    required this.bookId,
    required this.state,
    required this.rects,
    required this.origin,
    required this.pageSize,
  });

  final String bookId;
  final ReaderState state;

  /// 当前页的选区矩形（页内容盒坐标）——菜单贴着它们摆
  final List<Rect> rects;

  /// 内容盒在页面区域里的原点
  final Offset origin;

  /// 页面区域尺寸（用来夹住菜单，别跑出屏幕）
  final Size pageSize;

  @override
  ConsumerState<SelectionActions> createState() => _SelectionActionsState();
}

class _SelectionActionsState extends ConsumerState<SelectionActions> {
  /// 色板展开中
  bool _colorOpen = false;

  @override
  Widget build(BuildContext context) {
    final selection = widget.state.selection;
    if (selection == null || widget.rects.isEmpty) {
      return const SizedBox.shrink();
    }
    // 与这段选文相交的已有标注（最近的在前）：菜单按最新那条显示，
    // 保存时把它们与当前选区合成一条（N5 的合并口径）
    final overlapping = _overlapping(ref);
    final existing = overlapping.isEmpty ? null : overlapping.first;

    return CustomSingleChildLayout(
      delegate: _MenuLayout(
        anchorTop: widget.origin.dy + widget.rects.first.top,
        anchorBottom: widget.origin.dy + widget.rects.last.bottom,
        anchorLeft: widget.origin.dx + widget.rects.first.left,
        pageSize: widget.pageSize,
        gap: kSelectionMenuGap,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.pageSize.width - 2 * GtSpacing.s3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_colorOpen)
              _ColorRow(onPick: (color) => _applyColor(color, overlapping)),
            _MenuBar(
              existing: existing,
              onHighlight: () =>
                  _applyColor(AnnotationColor.yellow, overlapping),
              onColors: () => setState(() => _colorOpen = !_colorOpen),
              onWriteNote: () => _writeNote(context, overlapping),
              onDelete: existing == null ? null : () => _delete(overlapping),
            ),
          ],
        ),
      ),
    );
  }

  /// 与当前选文**相交**的已有标注，最近的在前。
  ///
  /// 只看位置（按阅读顺序比较），不看摘录文字：同一段话在书里可能出现多次；
  /// 用户拖手柄把范围调大一点之后，也仍然是在改同一条标注。
  List<Annotation> _overlapping(WidgetRef ref) {
    final selection = widget.state.selection;
    final list = ref.watch(annotationsProvider(widget.bookId)).value;
    if (selection == null || list == null || list.isEmpty) return const [];
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    if (session == null || session.chapters.isEmpty) return const [];
    final ordinals = chapterOrdinalsOf(session.chapters);
    final touched = {selection.start.chapterId, selection.end.chapterId};
    final result = <Annotation>[];
    for (final annotation in list) {
      final end = annotation.end ?? annotation.start;
      if (!touched.contains(annotation.start.chapterId) &&
          !touched.contains(end.chapterId)) {
        continue;
      }
      if (rangesIntersect(
        annotation.range,
        selection,
        chapterOrdinals: ordinals,
      )) {
        result.add(annotation);
      }
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// 高亮/改颜色：把这一段与相交的旧标注合成一条，颜色用这次选的，
  /// 想法沿用最新那条已有的（合并口径见 [_mergedTarget]）。
  Future<void> _applyColor(
    AnnotationColor? color,
    List<Annotation> overlapping,
  ) async {
    final target = await _mergedTarget(ref, overlapping);
    if (target == null || !mounted) return;
    final newest = overlapping.isEmpty ? null : overlapping.first;
    await _saveMerged(
      target: target,
      newest: newest,
      overlapping: overlapping,
      color: color,
      body: newest?.body ?? '',
    );
    if (!mounted) return;
    setState(() => _colorOpen = false);
    // 保存成功后把选区收成「只摆菜单」：手柄和临时底色撤掉，画面上只剩这一条
    // 高亮本身。否则临时底色叠在刚合并好的高亮上，看起来像高亮画了两遍、
    // 颜色更重（真机反馈）
    ref
        .read(readerProvider.notifier)
        .startSelection(target.range.start, target.range.end, fromMark: true);
    ref
        .read(readerProvider.notifier)
        .showNotice(newest == null ? '已加高亮' : '已改颜色');
  }

  /// 删除这一段上的标注（相交的旧记录一起删：它们本来就要合成一条）
  Future<void> _delete(List<Annotation> overlapping) async {
    final repository = ref.read(annotationRepositoryProvider);
    for (final annotation in overlapping) {
      await repository.deleteAnnotation(annotation.id);
    }
    if (!mounted) return;
    // 删完把选区一起收起：菜单跟着关掉，原书排版那边残留的矩形也一起作废
    // （不收起的话菜单会停在原地、按「没有标注」重画一遍，看着像没删掉）
    ref.read(readerProvider.notifier).clearSelection();
    setState(() => _colorOpen = false);
    ref.read(readerProvider.notifier).showNotice('已删除');
  }

  /// 写想法：这段选文上已有标注时先把相交的旧记录合成一条，再打开笔记面板。
  ///
  /// 有旧记录才先合并：面板里始终只编辑一条（保存即更新它），同一处不会并存
  /// 好几条高亮；全新的一段选文不动库，等用户真保存了才建记录——
  /// 打开面板又取消，不该凭空多出一条高亮。
  Future<void> _writeNote(
    BuildContext context,
    List<Annotation> overlapping,
  ) async {
    final target = await _mergedTarget(ref, overlapping);
    if (target == null || !context.mounted) return;
    final newest = overlapping.isEmpty ? null : overlapping.first;
    if (newest != null) {
      final id = await _saveMerged(
        target: target,
        newest: newest,
        overlapping: overlapping,
        color: newest.color,
        body: newest.body,
      );
      if (id == null || !context.mounted) return;
      // 合并保存后同样是「只摆菜单」的那段选文：面板后面的临时底色与手柄撤掉，
      // 免得叠在合并好的高亮上看起来颜色更重
      ref
          .read(readerProvider.notifier)
          .startSelection(target.range.start, target.range.end, fromMark: true);
    }
    // 面板自己负责保存/删除后的收尾（关面板 + 收选区 + 提示），这里只负责打开
    ref
        .read(readerProvider.notifier)
        .openNoteEditor(
          NoteEditorRequest(
            range: target.range,
            quote: target.quote,
            chapterTitle: target.chapterTitle,
            existing: newest,
          ),
        );
  }

  /// 当前选区 + 相交旧标注的并集，以及并集对应的完整摘录与章节标题。
  Future<({SelectionRange range, String quote, String chapterTitle})?>
  _mergedTarget(WidgetRef ref, List<Annotation> overlapping) async {
    final selection = widget.state.selection;
    if (selection == null) return null;
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    if (session == null || session.chapters.isEmpty) return null;
    final ordinals = chapterOrdinalsOf(session.chapters);
    var range = normalizeRange(selection, chapterOrdinals: ordinals);
    for (final annotation in overlapping) {
      range = unionRange(range, annotation.range, chapterOrdinals: ordinals);
    }
    return _resolveRange(ref, range);
  }

  /// 保存合并后的这一条：位置取并集、摘录取并集正文，其余记录删掉。
  ///
  /// 返回合并后那条记录的 id（[newest] 为 null 时是新建）。
  Future<String?> _saveMerged({
    required ({SelectionRange range, String quote, String chapterTitle}) target,
    required Annotation? newest,
    required List<Annotation> overlapping,
    required AnnotationColor? color,
    required String body,
  }) async {
    final repository = ref.read(annotationRepositoryProvider);
    final text = body.trim();
    final id = await repository.saveAnnotation(
      id: newest?.id,
      bookId: widget.bookId,
      kind: text.isEmpty ? AnnotationKind.highlight : AnnotationKind.note,
      range: target.range,
      quote: target.quote,
      body: body,
      color: color,
      chapterTitle: target.chapterTitle,
    );
    for (final annotation in overlapping) {
      if (annotation.id == id) continue;
      await repository.deleteAnnotation(annotation.id);
    }
    return id;
  }

  /// 某一范围对应的完整摘录（跨章按章节分段读取正文）。
  ///
  /// 选区跨到的章节都读一遍（当前章的正文已在会话里，其余章从正文仓库按需读），
  /// 摘录与范围都由 N3 那一层统一给出。
  Future<({SelectionRange range, String quote, String chapterTitle})?>
  _resolveRange(WidgetRef ref, SelectionRange selection) async {
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    if (session == null || session.chapters.isEmpty) return null;

    final ordinals = chapterOrdinalsOf(session.chapters);
    final startOrder = ordinals[selection.start.chapterId];
    final endOrder = ordinals[selection.end.chapterId];
    if (startOrder == null || endOrder == null) return null;
    final from = startOrder <= endOrder ? startOrder : endOrder;
    final to = startOrder <= endOrder ? endOrder : startOrder;

    final contents = <String, ChapterContent>{};
    final current = session.content;
    final repository = ref.read(chapterContentRepositoryProvider);
    for (final chapter in session.chapters) {
      if (chapter.ordinal < from || chapter.ordinal > to) continue;
      if (current != null && current.chapterId == chapter.id) {
        contents[chapter.id] = current;
      } else {
        contents[chapter.id] = await repository.chapter(widget.bookId, chapter);
      }
    }
    final resolved = resolveSelection(
      selection: selection,
      chapters: session.chapters,
      contentOf: (id) => contents[id]!,
    );
    return (
      range: resolved.range,
      quote: resolved.quote,
      chapterTitle: session.chapters[session.chapterIndex].title,
    );
  }
}

/// 一行操作按钮
class _MenuBar extends StatelessWidget {
  const _MenuBar({
    required this.existing,
    required this.onHighlight,
    required this.onColors,
    required this.onWriteNote,
    this.onDelete,
  });

  final Annotation? existing;
  final VoidCallback onHighlight;
  final VoidCallback onColors;
  final VoidCallback onWriteNote;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Material(
      color: colors.surface,
      elevation: 4,
      borderRadius: BorderRadius.circular(GtRadius.control),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: existing == null
            ? [
                _Action(
                  icon: GtIcons.highlight,
                  label: '高亮',
                  onTap: onHighlight,
                ),
                _Divider(color: colors.borderSubtle),
                _Action(
                  icon: GtIcons.notePlus,
                  label: '写想法',
                  onTap: onWriteNote,
                ),
              ]
            : [
                _Action(icon: GtIcons.palette, label: '颜色', onTap: onColors),
                _Divider(color: colors.borderSubtle),
                _Action(
                  icon: GtIcons.note,
                  label: existing!.isNote ? '编辑想法' : '写想法',
                  onTap: onWriteNote,
                ),
                _Divider(color: colors.borderSubtle),
                _Action(
                  icon: GtIcons.trash,
                  label: '删除',
                  color: colors.danger,
                  onTap: onDelete ?? () {},
                ),
              ],
      ),
    );
  }
}

/// 色板：黄 / 蓝 / 绿 / 无底色，各带文字标签
class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.onPick});

  final ValueChanged<AnnotationColor?> onPick;

  static const List<AnnotationColor?> _choices = [
    AnnotationColor.yellow,
    AnnotationColor.blue,
    AnnotationColor.green,
    null,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: GtSpacing.s1),
      child: Material(
        color: colors.surface,
        elevation: 4,
        borderRadius: BorderRadius.circular(GtRadius.control),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final color in _choices)
              GtButton.raw(
                onPressed: () => onPick(color),
                borderRadius: BorderRadius.circular(GtRadius.control),
                child: Container(
                  width: 52,
                  height: kSelectionColorRowHeight - 8,
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: highlightColorOf(color),
                    borderRadius: BorderRadius.circular(GtRadius.control / 2),
                    border: Border.all(color: colors.borderSubtle),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    color?.label ?? '无',
                    style: GtText.caption(colors.textPrimary)
                        .copyWith(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 22, color: color);
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final tint = color ?? colors.actionPrimary;
    return GtButton.raw(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(GtRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: GtSpacing.s4,
          vertical: GtSpacing.s2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GtIcon(icon, size: 20, color: tint),
            const SizedBox(width: GtSpacing.s2),
            Text(
              label,
              style: GtText.body(color ?? colors.textPrimary)
                  .copyWith(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把操作菜单摆在选区旁边，并**始终留在屏幕内**。
///
/// 默认摆在选区下方；下面放不下（页末那几行）就翻到选区上方；
/// 左右也要夹住——页末选区贴着右边，按选区的左边界摆会让菜单右半截出屏。
/// 位置用实际子组件尺寸算，色板展开后菜单变高也能重新摆对。
class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout({
    required this.anchorTop,
    required this.anchorBottom,
    required this.anchorLeft,
    required this.pageSize,
    required this.gap,
  });

  /// 选区上下沿与左沿（页面坐标）
  final double anchorTop;
  final double anchorBottom;
  final double anchorLeft;
  final Size pageSize;
  final double gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = anchorBottom + gap + childSize.height <= size.height;
    final double top = below
        ? anchorBottom + gap
        : anchorTop - gap - childSize.height;
    final left = anchorLeft.clamp(
      0.0,
      math.max(0.0, size.width - childSize.width),
    );
    final double maxTop = math.max(0.0, size.height - childSize.height);
    final double clampedTop = top.clamp(0.0, maxTop).toDouble();
    return Offset(left.toDouble(), clampedTop);
  }

  @override
  bool shouldRelayout(covariant _MenuLayout oldDelegate) =>
      oldDelegate.anchorTop != anchorTop ||
      oldDelegate.anchorBottom != anchorBottom ||
      oldDelegate.anchorLeft != anchorLeft ||
      oldDelegate.pageSize != pageSize ||
      oldDelegate.gap != gap;
}
