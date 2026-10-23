import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../app/di/app_providers.dart';
import '../../../../core/diagnostics/app_errors.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/book_cover_choice.dart';
import '../../../../platform/channels/preset_fonts.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/book_cover_resources.dart';
import '../../../core/widgets/gt_button.dart';
import '../view_models/book_cover_controller.dart';

int _columns(double width, TextScaler scale) =>
    (width / (100 + scale.scale(12))).floor().clamp(2, 5);

Future<void> showBookCoverSheet(
  BuildContext context,
  WidgetRef ref,
  List<Book> books, {
  bool global = false,
}) async {
  if (books.isEmpty && !global) return;
  await BookCoverResources.prepare();
  if (!context.mounted) return;
  if (PresetFonts.included) PresetFonts.prepare('gt-preset-lxgwzhenkai');
  final root = ref.read(libraryRootPathProvider);
  final defaults = global
      ? await ref.read(bookCoverRepositoryProvider).loadGlobal()
      : null;
  if (!context.mounted) return;
  final book = global
      ? _preview(BookFormat.txt, defaults?[BookFormat.txt])
      : books.first;
  final original = book.coverPath == null
      ? null
      : p.join(root, book.id, book.coverPath!);
  final current = ref.read(bookCoverFileProvider)(book);
  final width = MediaQuery.sizeOf(context).width;
  final columns = _columns(width, MediaQuery.textScalerOf(context));
  final coverWidth = (width - 40 - (columns - 1) * 20) / columns;
  final decodeWidth = (coverWidth * MediaQuery.devicePixelRatioOf(context))
      .round();
  // 默认图和当前导入图先解码，再整体推入选择页。
  for (final path in {
    original,
    current,
    if (defaults != null)
      ...defaults.values.map(
        (c) => c.imagePath == null ? null : p.join(root, c.imagePath!),
      ),
  }.nonNulls) {
    if (!context.mounted) return;
    await precacheImage(
      BookCover.imageProvider(path, decodeWidth, custom: path != original),
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
    enableDrag: false,
    isDismissible: false,
    shape: const RoundedRectangleBorder(),
    backgroundColor: context.gtColors.canvas,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => BookCoverSheet(
      books: global ? [book] : books,
      globalChoices: defaults,
      originalPath: original,
      currentPath: current,
    ),
  );
}

class BookCoverSheet extends ConsumerStatefulWidget {
  const BookCoverSheet({
    super.key,
    required this.books,
    this.globalChoices,
    this.originalPath,
    this.currentPath,
  });
  final List<Book> books;
  final Map<BookFormat, BookCoverChoice>? globalChoices;
  final String? originalPath, currentPath;
  @override
  ConsumerState<BookCoverSheet> createState() => _BookCoverSheetState();
}

class _BookCoverSheetState extends ConsumerState<BookCoverSheet> {
  bool busy = false;
  BookFormat format = BookFormat.txt;
  late final defaults = {...?widget.globalChoices};
  bool get global => widget.globalChoices != null;
  Book get book =>
      global ? _preview(format, defaults[format]) : widget.books.first;
  String? get currentPath => global
      ? (book.coverChoice?.imagePath == null
            ? null
            : p.join(
                ref.read(libraryRootPathProvider),
                book.coverChoice!.imagePath!,
              ))
      : widget.currentPath;

  Future<void> choose(BookCoverPreset? preset, {bool import = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final controller = ref.read(bookCoverControllerProvider);
      final ids = widget.books.map((b) => b.id).toList();
      final changed = import
          ? await controller.import(ids, format: global ? format : null)
          : await (global
                    ? ref
                          .read(bookCoverRepositoryProvider)
                          .saveGlobal(format, preset: preset)
                    : controller.select(ids, preset))
                .then((_) => true);
      if (mounted && changed) {
        if (!global) {
          Navigator.pop(context);
        } else {
          final next = await ref.read(bookCoverRepositoryProvider).loadGlobal();
          final image = next[format]?.imagePath;
          if (mounted && image != null) {
            final width = MediaQuery.sizeOf(context).width;
            final columns = _columns(width, MediaQuery.textScalerOf(context));
            final pixels =
                ((width - 40 - (columns - 1) * 20) /
                        columns *
                        MediaQuery.devicePixelRatioOf(context))
                    .round();
            await precacheImage(
              BookCover.imageProvider(
                p.join(ref.read(libraryRootPathProvider), image),
                pixels,
                custom: true,
              ),
              context,
              onError: (_, _) {},
            );
          }
          if (mounted) {
            setState(() {
              defaults
                ..clear()
                ..addAll(next);
            });
          }
        }
      }
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '更换封面失败');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final book = this.book;
    final choices = widget.books
        .map((b) => (b.coverChoice?.preset, b.coverChoice?.imagePath))
        .toSet();
    final same = global || choices.length == 1;
    return PopScope(
      canPop: !busy,
      child: SizedBox(
        height:
            MediaQuery.sizeOf(context).height -
            MediaQuery.paddingOf(context).top,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
                child: Row(
                  children: [
                    GtButton.icon(
                      onPressed: busy ? null : () => Navigator.pop(context),
                      tooltip: '返回',
                      icon: Icon(Icons.arrow_back, color: colors.textPrimary),
                    ),
                    const SizedBox(width: 8),
                    Text('书籍封面', style: GtText.pageTitle(colors.textPrimary)),
                    const Spacer(),
                    if (busy)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
              if (global)
                IgnorePointer(
                  ignoring: busy,
                  child: DefaultTabController(
                    length: _formats.length,
                    child: TabBar(
                      labelPadding: EdgeInsets.zero,
                      labelColor: colors.actionPrimary,
                      unselectedLabelColor: colors.textMuted,
                      indicatorColor: colors.actionPrimary,
                      onTap: (index) =>
                          setState(() => format = _formats[index]),
                      tabs: [for (final f in _formats) Tab(text: f.label)],
                    ),
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = MediaQuery.textScalerOf(context);
                    final columns = _columns(constraints.maxWidth, scale);
                    final width =
                        (constraints.maxWidth - 40 - (columns - 1) * 20) /
                        columns;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 20,
                        mainAxisSpacing: 24,
                        mainAxisExtent:
                            width / GtSize.coverAspectRatio +
                            scale.scale(14) * 1.5 +
                            10,
                      ),
                      itemCount: BookCoverPreset.values.length + 2,
                      itemBuilder: (_, index) {
                        final custom =
                            index == BookCoverPreset.values.length + 1;
                        final preset = index == 0 || custom
                            ? null
                            : BookCoverPreset.values[index - 1];
                        final label = custom ? '自定义' : preset?.label ?? '默认封面';
                        final selected =
                            same &&
                            (custom
                                ? book.coverChoice?.imagePath != null
                                : preset == null
                                ? book.coverChoice?.preset == null &&
                                      book.coverChoice?.imagePath == null
                                : book.coverChoice?.preset == preset);
                        return GtButton.raw(
                          key: ValueKey(
                            'cover-${custom ? 'custom' : preset?.code ?? 'default'}',
                          ),
                          onPressed: busy
                              ? null
                              : () => choose(preset, import: custom),
                          borderRadius: BorderRadius.zero,
                          child: Column(
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (custom &&
                                        book.coverChoice?.imagePath == null)
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: colors.borderControl,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.add,
                                          size: 36,
                                          color: colors.textMuted,
                                        ),
                                      )
                                    else
                                      BookCover(
                                        bookId: book.id,
                                        title: book.title,
                                        author: book.author,
                                        preset: preset,
                                        showImageText: custom,
                                        radius: 0,
                                        imagePath: custom
                                            ? currentPath
                                            : index == 0
                                            ? widget.originalPath
                                            : null,
                                      ),
                                    if (selected) ...[
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                color: colors.actionPrimary,
                                                width: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: Icon(
                                          Icons.check_circle,
                                          color: colors.actionPrimary,
                                          size: 22,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                label,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: colors.textPrimary,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _formats = [
  BookFormat.txt,
  BookFormat.epub,
  BookFormat.mobi,
  BookFormat.azw3,
  BookFormat.pdf,
];
Book _preview(BookFormat format, BookCoverChoice? choice) => Book(
  id: 'default-cover',
  sourceHash: '',
  title: '默认书名',
  author: '默认作者',
  format: format,
  importedAt: DateTime(2026),
  coverChoice: choice,
);
