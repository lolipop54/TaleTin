import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../core/diagnostics/app_errors.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/repositories/book_repository.dart';
import '../../../../domain/use_cases/delete_books.dart' show formatBytes;
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/book_cover_resources.dart';
import '../../../core/widgets/gt_button.dart';
import 'shelf_action_button.dart';

const _coverWidth = 80.0;

Future<void> showBookDetailsSheet(
  BuildContext context,
  WidgetRef ref,
  Book book,
) async {
  final repository = ref.read(bookRepositoryProvider);
  final coverPath = ref.read(bookCoverFileProvider)(book);
  if (book.coverChoice?.preset != null) {
    await BookCoverResources.prepare();
  } else if (coverPath != null) {
    // 以面板实际使用的尺寸解码，开场时封面和文字一起出现。
    final width = (_coverWidth * MediaQuery.devicePixelRatioOf(context))
        .round();
    await precacheImage(
      BookCover.imageProvider(
        coverPath,
        width,
        custom: book.coverChoice?.imagePath != null,
      ),
      context,
      onError: (_, _) {},
    );
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(),
    backgroundColor: context.gtColors.surface,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => _BookDetailsSheet(
      book: book,
      coverPath: coverPath,
      repository: repository,
    ),
  );
}

class _BookDetailsSheet extends StatefulWidget {
  const _BookDetailsSheet({
    required this.book,
    required this.coverPath,
    required this.repository,
  });

  final Book book;
  final String? coverPath;
  final BookRepository repository;

  @override
  State<_BookDetailsSheet> createState() => _BookDetailsSheetState();
}

class _BookDetailsSheetState extends State<_BookDetailsSheet> {
  late Book _book = widget.book;
  late final _title = TextEditingController(text: _book.title);
  late final _author = TextEditingController(text: _book.author);
  bool _editing = false;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    final author = _author.text.trim();
    if (title.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.repository.updateDisplayInfo(
        _book.id,
        title: title,
        author: author,
      );
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      _title.text = title;
      _author.text = author;
      setState(() {
        _book = _book.copyWith(title: title, author: author);
        _editing = false;
      });
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '保存书籍详情失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final style = GtText.caption(colors.textMuted).copyWith(fontSize: 13);
    final authorStyle = style.copyWith(color: colors.textPrimary);
    final titleStyle = authorStyle.copyWith(fontSize: 14);

    Widget line(String value, {TextStyle? styleOverride}) => Text(
      value,
      style: styleOverride ?? style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    Widget field({
      required TextEditingController controller,
      required String name,
      required String value,
      required TextStyle fieldStyle,
      required TextInputAction inputAction,
      String prefix = '',
    }) => SizedBox(
      height:
          MediaQuery.textScalerOf(context).scale(fieldStyle.fontSize!) * 1.4 +
          8,
      child: _editing
          ? Semantics(
              label: name,
              child: TextField(
                controller: controller,
                style: fieldStyle,
                readOnly: _saving,
                textInputAction: inputAction,
                onChanged: (_) => setState(() {}),
                onSubmitted: inputAction == TextInputAction.done
                    ? (_) => _save()
                    : null,
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 3),
                  prefixIcon: prefix.isEmpty
                      ? null
                      : Align(
                          widthFactor: 1,
                          heightFactor: 1,
                          child: ExcludeSemantics(
                            child: line(prefix, styleOverride: fieldStyle),
                          ),
                        ),
                  prefixIconConstraints: const BoxConstraints(),
                  border: const UnderlineInputBorder(),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: colors.textMuted),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: colors.actionPrimary),
                  ),
                ),
              ),
            )
          : Align(
              alignment: Alignment.centerLeft,
              child: line('$prefix$value', styleOverride: fieldStyle),
            ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: GtSpacing.s4),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '书籍详情',
                      style: GtText.sectionTitle(colors.textPrimary),
                    ),
                  ),
                  GtButton(
                    key: const ValueKey('book-details-edit-done'),
                    style: shelfSheetActionStyle(colors),
                    onPressed: !_editing
                        ? () => setState(() => _editing = true)
                        : _saving || _title.text.trim().isEmpty
                        ? null
                        : _save,
                    child: Text(_editing ? '完成' : '编辑'),
                  ),
                ],
              ),
              const SizedBox(height: GtSpacing.s2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _coverWidth,
                    child: BookCover(
                      bookId: _book.id,
                      title: _book.title,
                      author: _book.author,
                      imagePath: widget.coverPath,
                      preset: _book.coverChoice?.preset,
                      showImageText: _book.coverChoice?.imagePath != null,
                    ),
                  ),
                  const SizedBox(width: GtSpacing.s2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        field(
                          controller: _title,
                          name: '书名',
                          value: _book.title,
                          fieldStyle: titleStyle,
                          inputAction: TextInputAction.next,
                        ),
                        field(
                          controller: _author,
                          name: '作者',
                          value: _book.authorLabel,
                          fieldStyle: authorStyle,
                          inputAction: TextInputAction.done,
                          prefix: '作者：',
                        ),
                        const SizedBox(height: GtSpacing.s1),
                        line('大小：${formatBytes(_book.sizeBytes)}'),
                        const SizedBox(height: GtSpacing.s1),
                        line('格式：${_book.format.label}'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
