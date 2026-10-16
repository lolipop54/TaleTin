import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/statistics_providers.dart';
import '../../../../app/di/source_book_providers.dart';
import '../../../core/widgets/book_loading.dart';
import '../../../core/widgets/gt_button.dart';
import '../../bookshelf/view_models/prepare_shelf_return.dart';
import '../view_models/automatic_reading.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_source_change.dart';
import '../view_models/original_layout_controller.dart';
import '../view_models/reader_progress_return.dart';
import '../view_models/book_search_controller.dart';
import '../view_models/reader_view_model.dart';

class ReaderSourceChangedPage extends ConsumerStatefulWidget {
  const ReaderSourceChangedPage({super.key, required this.bookId});
  final String bookId;
  @override
  ConsumerState<ReaderSourceChangedPage> createState() => _SourceChangedState();
}

class _SourceChangedState extends ConsumerState<ReaderSourceChangedPage> {
  bool _leaving = false;
  bool _canPop = false;
  Object? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refresh);
  }

  Future<void> _refresh() async {
    if (_running || !mounted) return;
    setState(() {
      _running = true;
      _error = null;
    });
    final id = widget.bookId;
    try {
      await ref
          .read(readerProgressReturnProvider(id).notifier)
          .prepareJumpCover
          ?.call();
      await ref.read(readerSettingsProvider(id).notifier).pendingWrites;
      await ref.read(automaticReadingProvider(id).notifier).pause();
      await ref.read(readerSessionProvider(id).notifier).persist();
      if (!mounted) return;
      await ref.read(prepareSourceReadingProvider)(id);
      if (!mounted || _leaving) return;
      ref.invalidate(originalLayoutProvider(id));
      ref.invalidate(bookTocProvider(id));
      ref.read(bookSearchProvider(id).notifier).clear();
      ref.read(readerProvider.notifier).clearSelection();
      ref.invalidate(readerSessionProvider(id));
      await ref.read(readerSessionProvider(id).future);
      await ref.read(progressTitlesProvider(id).future);
      if (mounted) ref.read(readerSourceChangeProvider(id).notifier).complete();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _exit() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    // 切换选项已提交时仍等保存完成；不把错误页当作新阅读位置写回。
    await ref
        .read(readerSettingsProvider(widget.bookId).notifier)
        .pendingWrites;
    await ref.read(automaticReadingProvider(widget.bookId).notifier).pause();
    await ref.read(readerSessionProvider(widget.bookId).notifier).persist();
    await ref.read(readingStatisticsServiceProvider).leaveVisual();
    if (!mounted) return;
    await prepareShelfReturn(ref);
    if (!mounted) return;
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _exit();
    },
    child: ColoredBox(
      color: _error == null
          ? Colors.transparent
          : Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error == null)
                const BookLoading()
              else ...[
                const Text('源文件更新失败'),
                const SizedBox(height: 16),
                GtButton.filled(
                  onPressed: _running ? null : _refresh,
                  child: const Text('重试'),
                ),
                const SizedBox(height: 12),
                GtButton.filled(
                  onPressed: _leaving ? null : _exit,
                  child: const Text('退出'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
