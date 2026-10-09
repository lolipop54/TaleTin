import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/services/reader_image_sequence.dart';
import '../../../core/widgets/gt_button.dart';
import '../view_models/reader_session_view_model.dart';
import 'reader_gallery_frame.dart';
import 'reader_gallery_pager.dart';

/// 单张插图沿用旧查看器；连续图片使用画廊，关闭前回到最后看的图片。
Future<bool> tryReaderImageGallery(
  BuildContext context,
  WidgetRef ref,
  String bookId,
  String resourcePath, {
  String? chapterId,
  String? blockId,
}) async {
  final session = ref.read(readerSessionProvider(bookId)).requireValue;
  final sequence = await readerImageSequence(
    contents: ref.read(chapterContentRepositoryProvider),
    book: session.book,
    chapters: session.chapters,
    chapterId: chapterId ?? session.chapter.id,
    resourcePath: resourcePath,
    blockId: blockId,
  );
  if (sequence == null || sequence.images.length < 2) return false;
  if (!context.mounted) return true;
  final first = await ReaderGalleryFrame.load(
    sequence.images[sequence.initialIndex].path,
    context,
  );
  if (!context.mounted) {
    first.dispose();
    return true;
  }
  final notifier = ref.read(readerSessionProvider(bookId).notifier);
  final route = DialogRoute<void>(
    context: context,
    useSafeArea: false,
    barrierDismissible: false,
    barrierColor: Colors.black,
    builder: (_) => ReaderImageGallery(
      sequence: sequence,
      first: first,
      onClose: (index) => notifier.goToImage(sequence.images[index].locator),
    ),
  );
  await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return true;
}

/// 原书图片URL的前两段为书籍ID和正文版本，其余是归档内资源路径。
String galleryResourcePath(String url) =>
    'res/${Uri.parse(url).pathSegments.skip(2).join('/')}';

class ReaderImageGallery extends StatefulWidget {
  const ReaderImageGallery({
    super.key,
    required this.sequence,
    required this.first,
    required this.onClose,
    this.loadFrame = ReaderGalleryFrame.load,
  });
  final ReaderImageSequence sequence;
  final ReaderGalleryFrame first;
  final Future<void> Function(int index) onClose;
  final Future<ReaderGalleryFrame> Function(String, BuildContext) loadFrame;
  @override
  State<ReaderImageGallery> createState() => _ReaderImageGalleryState();
}

class _ReaderImageGalleryState extends State<ReaderImageGallery> {
  late int _index = widget.sequence.initialIndex;
  bool _loading = false, _closing = false;
  String? _error;

  Future<void> _close() async {
    if (_closing || _loading) return;
    setState(() => _closing = true);
    try {
      await widget.onClose(_index);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = '正文定位失败，请重试关闭图片');
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _close,
          child: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                AbsorbPointer(
                  absorbing: _closing,
                  child: ReaderGalleryPager(
                    first: widget.first,
                    initialIndex: widget.sequence.initialIndex,
                    count: widget.sequence.images.length,
                    load: (index, context) => widget.loadFrame(
                      widget.sequence.images[index].path,
                      context,
                    ),
                    onChanged: (index) => setState(() {
                      _index = index;
                      _error = null;
                    }),
                    onBusy: (busy) => _loading = busy,
                    onError: () => setState(() => _error = '图片无法打开，请重试'),
                    onBlankTap: _close,
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GtButton.icon(
                    tooltip: '关闭图片',
                    onPressed: _close,
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black54,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.close),
                  ),
                ),
                Positioned(
                  bottom: 16,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Text(
                      '${_index + 1} / ${widget.sequence.images.length}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ),
                if (_error != null)
                  Positioned(
                    bottom: 44,
                    left: 16,
                    right: 16,
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
