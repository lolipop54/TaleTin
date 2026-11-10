import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../platform/channels/preset_fonts.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'reader_option_route.dart';
import 'reader_performance.dart';
import '../../settings/views/global_font_view.dart';
import '../../settings/view_models/global_reading_settings.dart';

/// 名单与字体先就绪，再替换设置面板；订阅覆盖弹层整个生命周期。
Future<void> showReaderFontSheet(
  BuildContext context,
  WidgetRef ref,
  String bookId, {
  required bool supportsOriginalFont,
}) async {
  final container = ProviderScope.containerOf(context);
  final vm = ref.read(readerProvider.notifier);
  final lease = container.listen(readerSettingsProvider(bookId), (_, _) {});
  try {
    await measureReader(
      'font-sheet.catalog',
      () => container.read(fontFamilyNamesProvider.future),
    );
    await container.read(readerSettingsProvider(bookId).future);
    await container.read(fontOrderProvider.future);
    if (!context.mounted) return;
    await measureReader('font-sheet.previews', () async {
      PresetFonts.preparePreviews();
    });
    if (!context.mounted) return;
    await container.read(globalSettingsProvider.future);
    if (!context.mounted) return;
    await showReaderOption<void>(
      context,
      ref,
      (_) => ReaderFontSheet(
        bookId: bookId,
        supportsOriginalFont: supportsOriginalFont,
      ),
      bookId: bookId,
    );
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '打开字体列表失败');
    vm.showNotice('字体列表未能打开，请重试');
  } finally {
    lease.close();
  }
}

/// 阅读字体列表复用全局管理页，支持相同的编辑、导入、删除和排序。
class ReaderFontSheet extends StatelessWidget {
  const ReaderFontSheet({
    super.key,
    required this.bookId,
    this.supportsOriginalFont = true,
  });
  final String bookId;
  final bool supportsOriginalFont;
  @override
  Widget build(BuildContext context) => GlobalFontView(
    readerBookId: bookId,
    supportsOriginalFont: supportsOriginalFont,
  );
}
