import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/reading_theme.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_session_view_model.dart';

/// 一级与二级面板共用工具栏；二级面板禁用所属的一级入口。
class ReaderToolbar extends StatelessWidget {
  const ReaderToolbar({
    super.key,
    required this.theme,
    required this.onSelect,
    this.blocked,
  });
  final ReadingTheme theme;
  final ValueChanged<ReaderPanel>? onSelect;
  final ReaderPanel? blocked;
  @override
  Widget build(BuildContext context) => Container(
    color: theme.background,
    height: 87,
    child: Column(
      children: [
        Container(height: 1, color: theme.secondary.withValues(alpha: .18)),
        Expanded(
          child: Row(
            children: [
              for (final (index, item) in const [
                (ReaderPanel.contents, GtIcons.toc, '目录'),
                (ReaderPanel.brightness, GtIcons.brightness, '亮度'),
                (ReaderPanel.tts, GtIcons.headphones, '听书'),
                (ReaderPanel.auto, GtIcons.autoRead, '自动阅读'),
                (ReaderPanel.typography, GtIcons.settings, '设置'),
              ].indexed) ...[
                if (index > 0)
                  Container(
                    width: 1,
                    height: 36,
                    color: theme.secondary.withValues(alpha: .18),
                  ),
                Expanded(
                  child: GtButton.raw(
                    onPressed: onSelect == null || blocked == item.$1
                        ? null
                        : () => onSelect!(item.$1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GtIcon(item.$2, size: 24, color: theme.primary),
                        const SizedBox(height: GtSpacing.s1),
                        Text(
                          item.$3,
                          style: GtText.caption(
                            theme.primary,
                          ).copyWith(fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

/// 数据全部就绪后才切换面板，等待期间保留原面板。
Future<void> prepareReaderPanel(
  BuildContext context,
  ProviderContainer container,
  String bookId,
  ReaderPanel panel,
) async {
  if (panel == ReaderPanel.contents) {
    // 子路由打开时，父页的订阅会暂停；准备期间另持订阅，保证查询流继续工作。
    final toc = container.listen(bookTocProvider(bookId), (_, _) {});
    final bookmarks = container.listen(bookmarksProvider(bookId), (_, _) {});
    final notes = container.listen(annotationsProvider(bookId), (_, _) {});
    try {
      await Future.wait([
        container.read(bookTocProvider(bookId).future),
        container.read(bookmarksProvider(bookId).future),
        container.read(annotationsProvider(bookId).future),
      ]);
    } finally {
      toc.close();
      bookmarks.close();
      notes.close();
    }
  } else if (panel == ReaderPanel.tts) {
    await container.read(listeningServiceProvider).prepareVoices();
  } else if (panel == ReaderPanel.brightness) {
    await container.read(systemBrightnessProvider.future);
  }
}
