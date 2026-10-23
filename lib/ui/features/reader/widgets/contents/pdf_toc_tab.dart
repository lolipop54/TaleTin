import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/widgets/gt_button.dart';
import '../../../../core/widgets/book_loading.dart';
import '../../../../../data/services/pdf_book_controller.dart';
import '../../view_models/pdf_book_provider.dart';
import '../../view_models/reader_session_view_model.dart';
import '../../view_models/reader_progress_return.dart';
import '../../view_models/reader_view_model.dart';
import 'toc_tab.dart';
import 'toc_scrollbar.dart';

/// 缩略图和真实大纲共用目录页签；排序与视图按钮始终固定在列表上方。
class PdfTocTab extends ConsumerStatefulWidget {
  const PdfTocTab({super.key, required this.bookId});
  final String bookId;
  @override
  ConsumerState<PdfTocTab> createState() => _PdfTocTabState();
}

class _PdfTocTabState extends ConsumerState<PdfTocTab> {
  bool _thumbnails = true, _descending = false;
  ScrollController? _scroll;
  Object? _gridRevision;
  final _images = <int, Future<Uint8List>>{};
  Future<void> _thumbnailChain = Future.value();

  Future<Uint8List> _thumbnail(PdfBookController book, int index) {
    final result = Completer<Uint8List>();
    // 一次只准备一个缩略图；快速滚动时丢弃已离屏的请求，跳页不必排在整段目录后面。
    _thumbnailChain = _thumbnailChain.then((_) async {
      if (!mounted || !identical(_images[index], result.future)) {
        result.completeError(StateError('缩略图请求已失效'));
        return;
      }
      try {
        result.complete(await book.render(index, 240));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  Future<void> _open(int index) async {
    final book = await ref.read(pdfBookProvider(widget.bookId).future);
    if (!mounted) return;
    await ref.read(readerProgressReturnProvider(widget.bookId).notifier).jump(
      () async {
        final content = await book.content(index);
        if (!mounted) return;
        ref.read(readerProvider.notifier).closePanel(collapseControls: true);
        final session = ref.read(readerSessionProvider(widget.bookId).notifier);
        await session.goToLocator(
          content.pdfPage!.anchorAt(
            content,
            widget.bookId,
            content.chapterId,
            0,
          ),
        );
        await session.waitForTocPosition();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final book = ref.watch(pdfBookProvider(widget.bookId)).value;
    final session = ref.watch(readerSessionProvider(widget.bookId)).value;
    final toggle = GtButton(
      key: const Key('pdf-toc-view-button'),
      style: GtButton.compactStyle,
      onPressed: () => setState(() => _thumbnails = !_thumbnails),
      child: Text(
        _thumbnails ? '缩略图' : '列表',
        style: GtText.caption(colors.actionPrimary).copyWith(fontSize: 12),
      ),
    );
    if (!_thumbnails) {
      return TocTab(
        bookId: widget.bookId,
        query: '',
        leadingAction: toggle,
        descending: _descending,
        onOrderChanged: () => setState(() => _descending = !_descending),
      );
    }
    if (book == null || session == null) return const SizedBox.shrink();
    final count = book.chapters.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            GtSpacing.s5,
            GtSpacing.s2,
            GtSpacing.s3,
            GtSpacing.s1,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '共$count页',
                  style: GtText.caption(colors.textMuted)
                      .copyWith(fontSize: 12),
                ),
              ),
              toggle,
              GtButton(
                style: GtButton.compactStyle,
                onPressed: () => setState(() => _descending = !_descending),
                child: Text(
                  _descending ? '倒序' : '正序',
                  style: GtText.caption(colors.actionPrimary)
                      .copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 120).floor().clamp(2, 6);
              final itemWidth =
                  (constraints.maxWidth -
                      20 -
                      TocScrollbar.gutter -
                      (columns - 1) * 12) /
                  columns;
              final height = itemWidth / .7 + 28;
              final revision = (columns, _descending, _thumbnails);
              if (_gridRevision != revision) {
                _gridRevision = revision;
                final old = _scroll;
                final position = _descending
                    ? count - 1 - session.chapterIndex
                    : session.chapterIndex;
                final offset = ((position ~/ columns) * (height + 12)).clamp(
                  0.0,
                  ((count + columns - 1) ~/ columns) * (height + 12) -
                              constraints.maxHeight >
                          0
                      ? ((count + columns - 1) ~/ columns) * (height + 12) -
                            constraints.maxHeight
                      : 0.0,
                );
                _scroll = ScrollController(initialScrollOffset: offset);
                if (old != null) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => old.dispose(),
                  );
                }
              }
              return TocScrollbar(
                key: ObjectKey(_scroll),
                controller: _scroll!,
                child: GridView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(
                    20,
                    8,
                    TocScrollbar.gutter,
                    12,
                  ),
                  itemCount: count,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: height,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemBuilder: (context, position) {
                    final index = _descending ? count - 1 - position : position;
                    final selected = index == session.chapterIndex;
                    final bytes = _images.putIfAbsent(
                      index,
                      () => _thumbnail(book, index),
                    );
                    // 有界保留近期请求，离屏缩略图的解码由Flutter图片缓存回收。
                    while (_images.length > 32) {
                      _images.remove(_images.keys.first);
                    }
                    return GtButton.raw(
                      onPressed: () => _open(index),
                      child: Column(
                        children: [
                          Expanded(
                            child: Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: colors.subtle,
                                border: Border.all(
                                  color: selected
                                      ? colors.actionPrimary
                                      : colors.borderSubtle,
                                  width: selected ? 2 : 1,
                                ),
                              ),
                              child: FutureBuilder<Uint8List>(
                                future: bytes,
                                builder: (_, snapshot) => snapshot.hasData
                                    ? Image.memory(
                                        snapshot.data!,
                                        fit: BoxFit.contain,
                                        gaplessPlayback: true,
                                      )
                                    : snapshot.hasError
                                    ? IconButton(
                                        icon: const Icon(Icons.refresh),
                                        onPressed: () => setState(
                                          () => _images.remove(index),
                                        ),
                                      )
                                    : const Center(
                                        child: FittedBox(child: BookLoading()),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${index + 1}',
                            style: GtText.caption(
                              selected
                                  ? colors.actionPrimary
                                  : colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
