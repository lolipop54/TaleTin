part of '../views/reader_view.dart';

/// 笔记面板（实现计划 N4）：写想法、保存、草稿恢复。
///
/// 与阅读页其他面板同一种形态：贴在**键盘上方**的一层，键盘弹出时跟着
/// `viewInsets` 逐帧移动，不会出现「先滑到屏幕底部、再跳到键盘上面」。
///
/// 交互口径（对应 N4 的完成标志）：
/// - 保存成功才关闭；失败时输入与草稿都留着，就地重试；
/// - 返回 / 关闭时若有改动先问一句「放弃修改」；
/// - 切后台先落草稿，回来还能接着写，但它不算一条笔记；
/// - 颜色统一由选区菜单的「颜色」负责，这里不再放一份重复的入口。

/// 笔记面板：贴在键盘上方，保存/删除成功后连同选区一起收起。
class NoteEditorPanel extends ConsumerStatefulWidget {
  const NoteEditorPanel({
    super.key,
    required this.bookId,
    required this.request,
  });

  final String bookId;
  final NoteEditorRequest request;

  @override
  ConsumerState<NoteEditorPanel> createState() => _NoteEditorPanelState();
}

class _NoteEditorPanelState extends ConsumerState<NoteEditorPanel>
    with WidgetsBindingObserver {
  late NoteEditorController _controller;
  final TextEditingController _input = TextEditingController();

  /// 已经保存或明确放弃：关面板时不再回写草稿
  bool _finished = false;

  /// 上一次已处理的「请求关闭」序号
  int _closeToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = _createController(widget.request);
    unawaited(_restoreDraft());
  }

  NoteEditorController _createController(NoteEditorRequest request) =>
      NoteEditorController(
        bookId: widget.bookId,
        range: request.range,
        quote: request.quote,
        chapterTitle: request.chapterTitle,
        existing: request.existing,
        annotations: ref.read(annotationRepositoryProvider),
        drafts: ref.read(noteDraftRepositoryProvider),
      );

  /// 有这份选文的草稿就填回输入框
  Future<void> _restoreDraft() async {
    await _controller.load();
    if (!mounted || _controller.body.isEmpty) return;
    _input.text = _controller.body;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_controller.flushDraft());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 没走保存/放弃就关掉：把手上内容落成草稿
    if (!_finished) unawaited(_controller.flushDraft());
    _controller.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 返回键要关面板：阅读页把请求转成序号，这里按序号走一次确认流程
    ref.listen(readerProvider.select((s) => s.noteCloseToken), (_, token) {
      if (token != _closeToken) unawaited(_confirmClose());
    });
    final colors = context.gtColors;
    final media = MediaQuery.of(context);
    final compact = media.size.height - media.viewInsets.bottom < 450;
    return ReaderSheet(
      collapsible: false,
      title: widget.request.existing == null ? '写想法' : '编辑想法',
      subtitle: widget.request.chapterTitle.isEmpty
          ? null
          : widget.request.chapterTitle,
      onClose: () => unawaited(_confirmClose()),
      maxHeightFactor: compact ? 0.92 : 0.62,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _QuoteBlock(
                quote: widget.request.quote,
                color: _controller.color,
                maxLines: compact ? 1 : 2,
              ),
              const SizedBox(height: GtSpacing.s4),
              // 输入长度不再撑高面板；受剩余空间约束，长想法在框内滚动。
              Flexible(
                child: SizedBox(
                  height: 144,
                  child: TextField(
                    controller: _input,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    onChanged: _controller.updateBody,
                    style: GtText.body(colors.textPrimary)
                        .copyWith(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '写点什么…',
                      hintStyle: GtText.body(colors.textMuted)
                          .copyWith(fontSize: 16),
                      filled: true,
                      fillColor: colors.subtle,
                      contentPadding: const EdgeInsets.all(GtSpacing.s4),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(GtRadius.control),
                        borderSide: BorderSide(color: colors.borderSubtle),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(GtRadius.control),
                        borderSide: BorderSide(color: colors.borderSubtle),
                      ),
                    ),
                  ),
                ),
              ),
              if (_controller.error != null) ...[
                const SizedBox(height: GtSpacing.s2),
                Text(_controller.error!, style: GtText.caption(colors.danger)),
              ],
              const SizedBox(height: GtSpacing.s4),
              Row(
                children: [
                  Expanded(
                    child: _SaveButton(
                      saving: _controller.isSaving,
                      onPressed: _controller.canSave
                          ? () => unawaited(_save())
                          : null,
                    ),
                  ),
                  if (_controller.isEditingExisting) ...[
                    const SizedBox(width: GtSpacing.s3),
                    GtButton(
                      onPressed: _controller.isSaving
                          ? null
                          : () => unawaited(_remove()),
                      child: Text(
                        '删除',
                        style: GtText.body(colors.danger)
                            .copyWith(fontSize: 15),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: GtSpacing.s3),
            ],
          ),
        ),
      ),
    );
  }

  /// 保存成功才收起面板；失败留在原地，输入不丢。
  ///
  /// 改已有笔记时把想法删空，要先问清是「只留高亮」还是「删掉整条」，
  /// 不能自己替用户决定（实现计划 N5）。
  Future<void> _save() async {
    if (_controller.isEditingExisting && _controller.body.trim().isEmpty) {
      final choice = await _askEmptyNoteChoice();
      if (choice == null || !mounted) return;
      final done = switch (choice) {
        _EmptyNoteChoice.keepHighlight => await _controller.saveAsHighlight(),
        _EmptyNoteChoice.delete => await _controller.remove(),
      };
      if (!mounted || !done) return;
      _finish('已保存笔记');
      return;
    }
    final saved = await _controller.save();
    if (!mounted || !saved) return;
    _finish('已保存笔记');
  }

  /// 收尾：面板关掉、选区收起，并说一句结果
  void _finish(String notice) {
    _finished = true;
    ref
        .read(readerProvider.notifier)
        .closeNoteEditor(clearSelection: true, notice: notice);
  }

  Future<_EmptyNoteChoice?> _askEmptyNoteChoice() =>
      showDialog<_EmptyNoteChoice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: const Text('想法清空了，这条要怎么办？'),
          actions: [
            GtDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: '继续编辑',
            ),
            GtDialogAction(
              role: GtDialogActionRole.primary,
              onPressed: () =>
                  Navigator.of(dialogContext)
                      .pop(_EmptyNoteChoice.keepHighlight),
              label: '只留高亮',
            ),
            GtDialogAction(
              role: GtDialogActionRole.danger,
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_EmptyNoteChoice.delete),
              label: '删掉整条',
            ),
          ],
        ),
      );

  /// 删除整条标注（记录与草稿一起清掉）
  Future<void> _remove() async {
    final removed = await _controller.remove();
    if (!mounted || !removed) return;
    _finish('已删除');
  }

  /// 关闭只退出编辑器，保留正在调整的选区；有改动先确认放弃。
  Future<void> _confirmClose() async {
    _closeToken = ref.read(readerProvider).noteCloseToken;
    if (!_controller.hasUnsavedChanges) {
      _finished = true;
      await _controller.flushDraft();
      if (mounted) {
        ref.read(readerProvider.notifier).closeNoteEditor();
      }
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: const Text('这条想法还没保存，要放弃吗？'),
        actions: [
          GtDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            label: '继续编辑',
          ),
          GtDialogAction(
            role: GtDialogActionRole.danger,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            label: '放弃',
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    _finished = true;
    await _controller.discard();
    if (mounted) {
      ref.read(readerProvider.notifier).closeNoteEditor();
    }
  }
}

/// 清空想法后的处理方式
enum _EmptyNoteChoice { keepHighlight, delete }

/// 选文摘录：只露两行，多了打省略号；底色跟着这条笔记的颜色走
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.quote, this.color, this.maxLines = 2});

  final String quote;
  final AnnotationColor? color;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: GtSpacing.s3,
        vertical: GtSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: pageHighlightColorOf(color ?? AnnotationColor.yellow).withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? .24 : .45,
        ),
        borderRadius: BorderRadius.circular(GtRadius.control),
      ),
      child: Text(
        quote,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: GtText.body(colors.textPrimary)
            .copyWith(fontSize: 15, height: 1.4),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.saving, required this.onPressed});

  final bool saving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: GtSize.touchMin,
      child: GtButton.filled(
        onPressed: onPressed,
        child: saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('保存'),
      ),
    );
  }
}
