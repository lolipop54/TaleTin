import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/services/reader_image_sequence.dart';
import '../../../core/widgets/gt_button.dart';
import '../view_models/reader_session_view_model.dart';
import '../../../../app/di/source_book_providers.dart';
import '../view_models/reader_source_change.dart';
import '../../../../domain/models/book_document.dart';
import 'reader_gallery_frame.dart';
import 'reader_gallery_pager.dart';

/// 先显示点击的图片，再后台查找连续图片；关闭前回到最后看的图片。
Future<bool> tryReaderImageGallery(
  BuildContext context,
  WidgetRef ref,
  String bookId,
  String resourcePath, {
  String? chapterId,
  String? blockId,
  Future<ReaderGalleryFrame> Function(String, BuildContext) loadFrame =
      ReaderGalleryFrame.load,
}) async {
  final session = ref.read(readerSessionProvider(bookId)).requireValue;
  final contents = ref.read(chapterContentRepositoryProvider);
  final notifier = ref.read(readerSessionProvider(bookId).notifier);
  final imageChapters = <String, Chapter>{};
  Future<ReaderImageSequence?> sequence({
    bool currentOnly = false,
    bool Function()? isActive,
  }) async {
    final result = await readerImageSequence(
      contents: contents,
      book: session.book,
      chapters: session.chapters,
      chapterId: chapterId ?? session.chapter.id,
      resourcePath: resourcePath,
      blockId: blockId,
      currentOnly: currentOnly,
      isActive: isActive,
    );
    if (result != null) {
      for (final image in result.images) {
        imageChapters[image.path] = session.chapters.firstWhere(
          (chapter) => chapter.id == image.locator.chapterId,
        );
      }
    }
    return result;
  }

  Future<ReaderGalleryFrame> preparedFrame(
    String path,
    BuildContext context,
  ) async {
    // 查序不提取整本图片。展示目标前读它所在的一章，再解码完整资源。
    if (imageChapters[path] case final chapter?) {
      await contents.chapter(bookId, chapter);
    }
    if (!context.mounted) throw StateError('图片窗口已关闭');
    return loadFrame(path, context);
  }

  final initial = await sequence(currentOnly: true);
  if (initial == null) return false;
  if (!context.mounted) return true;
  ReaderGalleryFrame first;
  try {
    first = await preparedFrame(initial.images.single.path, context);
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '打开图片失败', notify: false);
    if (context.mounted) {
      AppErrors.report(appError, appStack, operation: '打开图片失败');
    }
    return true;
  }
  if (!context.mounted) {
    first.dispose();
    return true;
  }
  final route = DialogRoute<void>(
    context: context,
    useSafeArea: false,
    barrierDismissible: false,
    barrierColor: Colors.black,
    builder: (_) => ReaderImageGallery(
      sequence: initial,
      first: first,
      loadSequence: (isActive) => sequence(isActive: isActive),
      loadFrame: preparedFrame,
      onClose: (locator) async {
        if (ref.read(readerSourceChangeProvider(bookId))) return;
        final current = ref.read(readerSessionProvider(bookId)).value;
        if (current == null) return;
        if (!identical(current.book, session.book)) {
          final found = await ref
              .read(sourcePositionResolverProvider)
              .resolve(
                locator.copyWith(needsRelocation: true),
                current.chapters,
              );
          if (found == null) return;
          locator = found;
        }
        try {
          await notifier.goToImage(locator);
        } catch (error) {
          if (!isSourceChange(error) &&
              !ref.read(readerSourceChangeProvider(bookId))) {
            rethrow;
          }
          ref.read(readerSourceChangeProvider(bookId).notifier).markChanged();
        }
      },
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
    this.loadSequence,
    this.loadFrame = ReaderGalleryFrame.load,
  });
  final ReaderImageSequence sequence;
  final ReaderGalleryFrame first;
  final Future<void> Function(Locator locator) onClose;
  final Future<ReaderImageSequence?> Function(bool Function() isActive)?
  loadSequence;
  final Future<ReaderGalleryFrame> Function(String, BuildContext) loadFrame;
  @override
  State<ReaderImageGallery> createState() => _ReaderImageGalleryState();
}

class _ReaderImageGalleryState extends State<ReaderImageGallery> {
  late ReaderImageSequence _sequence = widget.sequence;
  late int _index = widget.sequence.initialIndex;
  late bool _discovering = widget.loadSequence != null;
  bool _loading = false, _closing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 当前图先画出来，整段图片数量和邻图准备都不参与窗口首次打开的等待。
    WidgetsBinding.instance.addPostFrameCallback((_) => _discover());
  }

  Future<void> _discover() async {
    final load = widget.loadSequence;
    if (load == null || !mounted) return;
    try {
      final complete = await load(() => mounted);
      if (!mounted) return;
      if (complete == null) throw StateError('图片顺序无法读取');
      setState(() {
        _sequence = complete;
        _index = complete.initialIndex;
        _discovering = false;
      });
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '读取其他图片失败');
      if (mounted) {
        setState(() {
          _discovering = false;
          _error = '其他图片读取失败，请重新打开重试';
        });
      }
    }
  }

  Future<void> _close() async {
    if (_closing || _loading) return;
    setState(() => _closing = true);
    try {
      await widget.onClose(_sequence.images[_index].locator);
      if (mounted) Navigator.of(context).pop();
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '返回图片位置失败');
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
                    initialIndex: _sequence.initialIndex,
                    count: _sequence.images.length,
                    load: (index, context) =>
                        widget.loadFrame(_sequence.images[index].path, context),
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
                if (_discovering || _sequence.images.length > 1)
                  Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Text(
                        _discovering
                            ? '正在准备其他图片…'
                            : '${_index + 1} / ${_sequence.images.length}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
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
