import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/forui_theme.dart';
import '../view_models/reader_settings_view_model.dart';

/// 只覆盖阅读区域；独立打开的子路由也读取同一本书的主题。
class ReaderControlTheme extends ConsumerWidget {
  const ReaderControlTheme({
    super.key,
    required this.bookId,
    required this.child,
  });
  final String? bookId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (bookId == null) return child;
    final theme =
        ref.watch(readerSettingsProvider(bookId!)).value?.theme ??
        ReaderSettingsState.fromGlobal(
          ref.watch(globalReadingPreferencesProvider),
        ).theme;
    return Theme(
      data: GtTheme.reading(
        theme,
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
      ),
      child: GtForuiTheme(child: child),
    );
  }
}
