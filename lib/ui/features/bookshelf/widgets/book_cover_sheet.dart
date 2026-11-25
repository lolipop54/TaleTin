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
import '../../../core/widgets/edge_to_edge_sheet.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../view_models/book_cover_controller.dart';

int _columns(double width, TextScaler scale) =>
    (width / (100 + scale.scale(12))).floor().clamp(2, 8);

Future<void> showBookCoverSheet(
  BuildContext context,
  WidgetRef ref,
  List<Book> books, {
  bool global = false,
}) async {
  final page = await prepareBookCoverSheet(context, ref, books, global: global);
  if (!context.mounted || page == null) return;
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: false,
    enableDrag: false,
    isDismissible: false,
    shape: const RoundedRectangleBorder(),
    backgroundColor: context.gtColors.canvas,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => EdgeToEdgeSheet(fullHeight: true, child: page),
  );
}

/// 弹层与桌面设置子页共用图库准备过程，按即将显示的列宽解码。
Future<BookCoverSheet?> prepareBookCoverSheet(
  BuildContext context,
  WidgetRef ref,
  List<Book> books, {
  bool global = false,
  double? width,
}) async {
  if (books.isEmpty && !global) return null;
  await BookCoverResources.prepare();
  if (!context.mounted) return null;
  if (PresetFonts.included) PresetFonts.prepare('gt-preset-lxgwzhenkai');
  final root = ref.read(libraryRootPathProvider);
  final repository = ref.read(bookCoverRepositoryProvider);
  final images = await repository.images();
  final defaults = await repository.loadGlobal();
  final updated = <Book>[];
  if (!global) {
    // 打开图库时可能已把旧版封面迁到共享目录，使用更新后的选择。
    final choices = await repository.loadBooks(books.map((book) => book.id));
    for (final book in books) {
      updated.add(
        book.copyWith(coverChoice: choices[book.id] ?? defaults[book.format]),
      );
    }
  }
  if (!context.mounted) return null;
  final book = global
      ? _preview(BookFormat.txt, defaults[BookFormat.txt])
      : updated.first;
  final original = book.coverPath == null
      ? null
      : p.join(root, book.id, book.coverPath!);
  final current = ref.read(bookCoverFileProvider)(book);
  final window = Navigator.of(context, rootNavigator: true).context;
  final available = width ??
      (MediaQuery.sizeOf(window).width - MediaQuery.paddingOf(window).horizontal);
  final columns = _columns(available, MediaQuery.textScalerOf(context));
  final coverWidth = (available - 40 - (columns - 1) * 20) / columns;
  final decodeWidth = (coverWidth * MediaQuery.devicePixelRatioOf(context))
      .round();
  // 默认图和当前导入图先解码，再整体推入选择页。
  for (final path in {
    original,
    current,
    if (global)
      ...defaults.values.map(
        (c) => c.imagePath == null ? null : p.join(root, c.imagePath!),
      ),
  }.nonNulls) {
    if (!context.mounted) return null;
    await precacheImage(
      BookCover.imageProvider(path, decodeWidth, custom: path != original),
      context,
      onError: (_, _) {},
    );
  }
  if (!context.mounted) return null;
  return BookCoverSheet(
    books: global ? [book] : updated,
    globalChoices: global ? defaults : null,
    originalPath: original,
    images: images,
  );
}

class BookCoverSheet extends ConsumerStatefulWidget {
  const BookCoverSheet({
    super.key,
    required this.books,
    this.globalChoices,
    this.originalPath,
    this.images = const [],
  });
  final List<Book> books;
  final Map<BookFormat, BookCoverChoice>? globalChoices;
  final String? originalPath;
  final List<String> images;
  @override
  ConsumerState<BookCoverSheet> createState() => _BookCoverSheetState();
}

class _BookCoverSheetState extends ConsumerState<BookCoverSheet> {
  bool busy = false;
  BookFormat format = BookFormat.txt;
  late final defaults = {...?widget.globalChoices};
  late final _imported = [...widget.images];
  late List<Book> _books = widget.books;
  bool get global => widget.globalChoices != null;
  Book get book => global ? _preview(format, defaults[format]) : _books.first;

  Future<void> choose(BookCoverPreset? preset, {String? image}) =>
      _run(() async {
        final repo = ref.read(bookCoverRepositoryProvider);
        if (global) {
          final selectedFormat = format;
          await repo.saveGlobal(
            selectedFormat,
            preset: preset,
            existingImage: image,
          );
          if (mounted) {
            setState(
              () => defaults[selectedFormat] = BookCoverChoice(
                preset: preset,
                imagePath: image,
              ),
            );
          }
        } else {
          await repo.save(
            widget.books.map((book) => book.id),
            preset: preset,
            existingImage: image,
          );
          if (mounted) Navigator.pop(context);
        }
      });

  Future<void> _import() => _run(() async {
    try {
      final added = await ref.read(bookCoverControllerProvider).import();
      if (!mounted || added.isEmpty) return;
      setState(() => _imported.addAll(added));
    } on FormatException catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: context.gtColors.surface,
          title: Text(error.message),
          actions: [
            GtDialogAction(
              label: '确定',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      );
    }
  }, operation: '导入封面失败');

  Future<void> _delete(String image, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.gtColors.surface,
        title: Text('删除$label？'),
        content: const Text('图片将从共享图库移除。使用这张图的书籍和格式将恢复默认封面。'),
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
    if (confirmed != true || !mounted) return;
    await _run(() async {
      final repository = ref.read(bookCoverRepositoryProvider);
      await repository.removeImage(image);
      final updatedDefaults = await repository.loadGlobal();
      final choices = global
          ? const <String, BookCoverChoice>{}
          : await repository.loadBooks(_books.map((book) => book.id));
      if (!mounted) return;
      setState(() {
        _imported.remove(image);
        defaults
          ..clear()
          ..addAll(updatedDefaults);
        if (!global) {
          _books = [
            for (final book in _books)
              book.copyWith(
                coverChoice:
                    choices[book.id] ??
                    updatedDefaults[book.format] ??
                    const BookCoverChoice(),
              ),
          ];
        }
      });
    }, operation: '删除封面失败');
  }

  Future<void> _run(
    Future<void> Function() action, {
    String operation = '更换封面失败',
  }) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: operation);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final book = this.book;
    final choices = _books
        .map((b) => (b.coverChoice?.preset, b.coverChoice?.imagePath))
        .toSet();
    final same = global || choices.length == 1;
    final selectedImage = book.coverChoice?.imagePath;
    final root = ref.watch(libraryRootPathProvider);
    final firstImage = BookCoverPreset.values.length + 1;
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
                      showTooltipOnWindows: false,
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
                      itemCount: firstImage + _imported.length + 1,
                      itemBuilder: (_, index) {
                        final add = index == firstImage + _imported.length;
                        final image = index >= firstImage && !add
                            ? _imported[index - firstImage]
                            : null;
                        final preset = index > 0 && index < firstImage
                            ? BookCoverPreset.values[index - 1]
                            : null;
                        final label = add
                            ? '导入封面'
                            : image != null
                            ? '自定义 ${index - firstImage + 1}'
                            : preset?.label ?? '默认封面';
                        final selected =
                            same &&
                            !add &&
                            selectedImage == image &&
                            (image != null ||
                                book.coverChoice?.preset == preset);
                        return GtButton.raw(
                          key: ValueKey(
                            'cover-${add ? 'custom' : image ?? preset?.code ?? 'default'}',
                          ),
                          onPressed: busy
                              ? null
                              : add
                              ? _import
                              : () => choose(preset, image: image),
                          onLongPress: busy || image == null
                              ? null
                              : () => _delete(image, label),
                          borderRadius: BorderRadius.zero,
                          child: Column(
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (add)
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
                                        showImageText: image != null,
                                        radius: 0,
                                        imagePath: image != null
                                            ? p.join(root, image)
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
