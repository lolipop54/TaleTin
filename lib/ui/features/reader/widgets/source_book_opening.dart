import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/source_book_providers.dart';
import '../../../../app/router/reader_route_page.dart';
import '../../../core/widgets/book_loading.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';

/// 进入阅读路由时显式准备来源。完整提交后才创建阅读会话，重建界面不重导入。
class SourceBookOpening extends ConsumerStatefulWidget {
  const SourceBookOpening({
    super.key,
    required this.bookId,
    required this.child,
  });
  final String bookId;
  final Widget child;
  @visibleForTesting
  static bool prepared(BuildContext context) =>
      context is StatefulElement &&
      context.state is _SourceBookOpeningState &&
      (context.state as _SourceBookOpeningState)._ready;
  @override
  ConsumerState<SourceBookOpening> createState() => _SourceBookOpeningState();
}

class _SourceBookOpeningState extends ConsumerState<SourceBookOpening> {
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    if (_error != null) setState(() => _error = null);
    try {
      await traceReaderWork(
        'reader.prepare-source',
        () => ref.read(prepareSourceReadingProvider)(widget.bookId),
        {'bookId': widget.bookId},
      );
      BookOpeningTrace.mark(widget.bookId, 'source_prepared');
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      BookOpeningTrace.finish(widget.bookId, status: 'prepare_failed');
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    if (_error != null) {
      final onReady = ReaderPageReady.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onReady?.call();
      });
    }
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: _error == null
            ? const BookLoading()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('书籍准备失败'),
                  const SizedBox(height: 16),
                  GtButton.filled(onPressed: _prepare, child: const Text('重试')),
                  const SizedBox(height: 12),
                  GtButton.filled(
                    onPressed: () => context.pop(),
                    child: const Text('退出'),
                  ),
                ],
              ),
      ),
    );
  }
}
