import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../domain/models/reading_statistics.dart';
import '../../../../domain/services/reading_segment_slicer.dart';
import '../../../../platform/channels/system_toast.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../view_models/statistics_providers.dart';
import 'reading_day_row.dart';
import 'reading_day_summary.dart';

Future<void> showReadingDay(
  BuildContext context,
  StatisticsPageData data,
  DateTime now,
  String date,
) async {
  // Read only the selected day's sessions and pieces; leave the previous screen
  // visible until both records and covers are ready, as with the original sheet.
  StatisticsPageData detail;
  try {
    detail = await data.loadDay?.call(date) ?? data;
  } catch (_) {
    if (context.mounted) await SystemToast.show('阅读记录暂时无法读取，请稍后重试');
    return;
  }
  if (!context.mounted) return;
  // 按书汇总当天的有效片段，同书多次阅读及听书共用一条记录。
  final books = detail.summary(now).booksOn(date);
  final width = (32 * MediaQuery.devicePixelRatioOf(context)).round();
  // 封面与真实记录一并准备，面板打开后不再从空图跳成封面。
  await Future.wait(
    books.keys
        .map((id) => detail.bookCovers[id])
        .whereType<String>()
        .toSet()
        .map(
          (path) => precacheImage(
            ResizeImage(FileImage(File(path)), width: width),
            context,
            onError: (_, _) {},
          ),
        ),
  );
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.gtColors.surface,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(),
    clipBehavior: Clip.antiAlias,
    builder: (_) =>
        ReadingDaySheet(data: detail, now: now, date: date, books: books),
  );
}

/// 日期详情使用打开时已准备的完整快照，期间不混入刷新后的部分记录。
class ReadingDaySheet extends StatelessWidget {
  const ReadingDaySheet({
    super.key,
    required this.data,
    required this.now,
    required this.date,
    required this.books,
  });
  final StatisticsPageData data;
  final DateTime now;
  final String date;
  final Map<String, DailyReadingStats> books;
  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final day = DateTime.parse(date);
    final weekday = ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1];
    final entries = books.entries.toList(growable: false);
    // 少量书籍时贴合内容，较多书籍时只滚动列表，不留下整屏空白。
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .78,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          date == readingDate(now) ? '今日阅读时长明细' : '阅读时长明细',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${day.month}月${day.day}日 · 星期$weekday',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  GtButton.raw(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.subtle,
                      ),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
              child: ReadingDaySummary(
                totalMs: data.summary(now).day(date).totalMs,
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: entries.isEmpty
                  ? SizedBox(
                      height: 120,
                      child: Center(
                        child: Text(
                          '这一天还没有阅读记录',
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(24, 0, 22, 24),
                      itemCount: entries.length,
                      itemBuilder: (_, index) => ReadingDayRow(
                        key: ValueKey('reading-day-book-${entries[index].key}'),
                        bookId: entries[index].key,
                        stats: entries[index].value,
                        data: data,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
