import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../../domain/services/toc_entry_index.dart';
import '../../../core/theme/reading_theme.dart';
import '../../settings/view_models/settings_view_model.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'page_information.dart';
import 'search_return_bar.dart';

/// 页首与页尾的数据取自该页所在章节，不依赖当前已提交的阅读页。
PageInformation readerInformation(
  BuildContext context,
  WidgetRef ref,
  ReaderSession session,
  ReadingSettings settings,
  ReadingTheme theme,
  int chapterIndex,
  double fraction, {
  bool showReturnProgress = true,
  bool bookmarked = false,
}) {
  final now = ref.watch(readerClockProvider)();
  final titles = ref.watch(progressTitlesProvider(session.book.id)).value;
  final chapter = session.chapters[chapterIndex];
  final title = titles == null || titles.isEmpty
      ? chapter.title
      : titles[tocEntryIndexAt(
              titles,
              position: session.bookProgressAt(chapterIndex, fraction),
              chapterId: chapter.id,
            )]
            .title;
  final menu = ref.watch(searchMenuAppearanceProvider(session.book.id));
  return PageInformation(
    bookmarked: bookmarked,
    fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
    searchMenu: settings.pageTurnEffect == PageTurnEffect.scroll
        ? null
        : (!showReturnProgress ? null : menu),
    chapter: title,
    book: session.book.title,
    progress:
        '${(session.bookProgressAt(chapterIndex, fraction) * 100).toStringAsFixed(2)}%',
    clock:
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    battery: ref.watch(batteryLevelProvider).value,
    inset: settings.horizontalPadding,
    // 正文区在 Scaffold 里，底部的系统栏留白已经被 Scaffold 扣掉了；
    // 这里用 paddingOf 拿到的是扣完的值（键盘弹出时同样稳定）
    bottomInset: MediaQuery.paddingOf(context).bottom,
    color: theme.secondary,
    scaler: MediaQuery.textScalerOf(context),
    visible: ref.watch(statusInfoVisibleProvider).value ?? true,
  );
}
