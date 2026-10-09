import 'package:flutter/material.dart';

import '../../../../domain/models/reading_statistics.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_cover.dart';
import '../view_models/statistics_providers.dart';

/// 一本书在选中日期的汇总，不用首次进入到最后退出的时间推算时长。
class ReadingDayRow extends StatelessWidget {
  const ReadingDayRow({
    super.key,
    required this.bookId,
    required this.stats,
    required this.data,
  });
  final String bookId;
  final DailyReadingStats stats;
  final StatisticsPageData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final mode = stats.visualMs > 0
        ? (stats.audioMs > 0 ? '专注阅读 · 听书' : '专注阅读')
        : '听书';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.borderSubtle.withValues(alpha: .5)),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 45,
            child: BookCover(
              bookId: bookId,
              title: data.title(bookId),
              author: '',
              imagePath: data.bookCovers[bookId],
              radius: 3,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  data.title(bookId),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  mode,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            readingDuration(stats.totalMs),
            style: TextStyle(fontSize: 12, color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}
