import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/device_status_providers.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../../domain/services/toc_entry_index.dart';
import '../../../core/theme/reading_theme.dart';
import '../../settings/view_models/settings_view_model.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'page_information.dart';
import 'book_paper.dart';
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
  int? spreadSide,
}) {
  // 系统分钟、校时、电量及恢复前台都会重建信息；正文排版参数不变。
  ref.watch(deviceStatusChangesProvider);
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
  final showNavigationBar =
      ref.watch(readingControlsProvider).value?.navigationBar ?? true;
  return PageInformation(
    bookmarked: bookmarked,
    bookEdges: settings.bookEdges,
    paper: theme.background,
    spreadSide: spreadSide,
    spread: settings.spreadEnabled && spreadSide == null,
    fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
    searchMenu: settings.pageTurnEffect == PageTurnEffect.scroll
        ? null
        : (!showReturnProgress ? null : menu),
    chapter: title,
    book: session.book.title,
    progress:
        '${(session.readingProgressAt(chapterIndex, fraction) * 100).toStringAsFixed(2)}%',
    clock:
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    battery: ref.watch(batteryLevelProvider).value,
    inset:
        settings.horizontalPadding + (settings.bookEdges ? bookEdgeWidth : 0),
    // 显示导航栏时由外层 SafeArea 消耗占位；隐藏时，Home 手势仍可能让
    // 系统短暂回报底部 padding。它不属于正文，不能触发重排并改写页首位置。
    bottomInset: showNavigationBar ? MediaQuery.paddingOf(context).bottom : 0,
    color: theme.secondary,
    scaler: MediaQuery.textScalerOf(context),
    visible: ref.watch(statusInfoVisibleProvider).value ?? true,
  );
}
