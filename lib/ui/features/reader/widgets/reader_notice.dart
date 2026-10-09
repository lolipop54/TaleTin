part of '../views/reader_view.dart';

/// 首屏准备态：排版参数已提交，等第一页排版结果（设计文档 9.7）
class _PreparingState extends StatelessWidget {
  const _PreparingState();

  @override
  Widget build(BuildContext context) => const Center(
    child: BookLoading(),
  );
}

/// 排版失败：给出原因与重试入口。
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(GtSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: GtText.body(theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: GtSpacing.s4),
            GtButton.filled(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 全书首尾、原书排版不可用等一次性提示。
class _ReaderNotice extends ConsumerStatefulWidget {
  const _ReaderNotice({super.key, required this.text});

  final String text;

  @override
  ConsumerState<_ReaderNotice> createState() => _ReaderNoticeState();
}

class _ReaderNoticeState extends ConsumerState<_ReaderNotice> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) ref.read(readerProvider.notifier).clearNotice();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.gtColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.textPrimary.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(GtRadius.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: GtSpacing.s4,
          vertical: GtSpacing.s2,
        ),
        child: Text(
          widget.text,
          style: GtText.caption(theme.surface).copyWith(fontSize: 12),
        ),
      ),
    );
  }
}
