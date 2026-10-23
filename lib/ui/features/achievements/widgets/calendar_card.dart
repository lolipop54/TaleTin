import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/models/reading_statistics.dart';
import '../../../../domain/services/reading_segment_slicer.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import 'calendar_month_pager.dart';

/// 阅读月历卡片（参考图 04）：
/// 周一起始，按有效阅读分钟五档着色，含图例与「今天」选中态。
class CalendarCard extends StatefulWidget {
  const CalendarCard({
    super.key,
    required this.days,
    required this.today,
    this.dayIndex,
    this.onDate,
  });
  final List<DailyReadingStats> days;
  final DateTime today;
  final Map<String, DailyReadingStats>? dayIndex;
  final Future<void> Function(String)? onDate;
  @override
  State<CalendarCard> createState() => _CalendarCardState();
}

class _CalendarCardState extends State<CalendarCard> {
  List<DailyReadingStats>? _indexedDays;
  Map<String, DailyReadingStats> _daysByDate = {};
  late String selected = readingDate(widget.today);
  bool _opening = false;

  /// 热度五档底色：0 / 1–14 / 15–29 / 30–59 / ≥60 分钟
  static int _heatLevel(int minutes) {
    if (minutes <= 0) return 0;
    if (minutes < 15) return 1;
    if (minutes < 30) return 2;
    if (minutes < 60) return 3;
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    if (!identical(_indexedDays, widget.days)) {
      _indexedDays = widget.days;
      _daysByDate = widget.dayIndex ?? {};
      if (widget.dayIndex == null) {
        for (final day in widget.days) {
          _daysByDate.putIfAbsent(day.date, () => day);
        }
      }
    }
    final colors = context.gtColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(GtRadius.card),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: CalendarMonthPager(
        initialMonth: widget.today,
        builder: (month) => Padding(
          padding: const EdgeInsets.fromLTRB(
            GtSpacing.s4,
            GtSpacing.s5,
            GtSpacing.s4,
            GtSpacing.s4,
          ),
          child: _monthBody(month),
        ),
      ),
    );
  }

  Widget _monthBody(DateTime month) {
    final colors = context.gtColors;
    final previousEnd = DateTime(month.year, month.month, 0).day;
    final leadingBlanks = [
      for (var i = month.weekday - 2; i >= 0; i--) previousEnd - i,
    ];
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final trailingCount = (7 - ((leadingBlanks.length + daysInMonth) % 7)) % 7;

    return Column(
      key: ValueKey(month),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            '${month.year}年${month.month.toString().padLeft(2, '0')}月',
            style: GtText.pageTitle(colors.textPrimary).copyWith(fontSize: 19),
          ),
        ),
        const SizedBox(height: GtSpacing.s4),
        // 星期表头（一 二 三 四 五 六 日）
        Row(
          children: [
            for (final wd in ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Center(
                  child: Text(
                    wd,
                    style: GtText.caption(colors.textSecondary)
                        .copyWith(fontSize: 12.5),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: GtSpacing.s2),
        // 日期网格
        for (
          var week = 0;
          week < (leadingBlanks.length + daysInMonth + trailingCount) ~/ 7;
          week++
        )
          Padding(
            padding: const EdgeInsets.only(bottom: GtSpacing.s2),
            child: Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _dayCell(
                      month,
                      week,
                      col,
                      leadingBlanks,
                      daysInMonth,
                      trailingCount,
                      colors,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: GtSpacing.s1),
        // 图例（窄屏整体缩放）
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legendSwatch(0, '0'),
              _legendSwatch(1, '1–14'),
              _legendSwatch(2, '15–29'),
              _legendSwatch(3, '30–59'),
              _legendSwatch(4, '≥60分钟'),
            ],
          ),
        ),
      ],
    );
  }

  /// 单元格：index = week*7 + col。
  Widget _dayCell(
    DateTime month,
    int week,
    int col,
    List<int> leadingBlanks,
    int daysInMonth,
    int trailingCount,
    GtColors colors,
  ) {
    final index = week * 7 + col;
    final today = widget.today;
    String? label;
    int? day;
    bool isOutMonth = false;

    if (index < leadingBlanks.length) {
      label = '${leadingBlanks[index]}';
      isOutMonth = true;
    } else if (index < leadingBlanks.length + daysInMonth) {
      day = index - leadingBlanks.length + 1;
      label = '$day';
    } else if (index < leadingBlanks.length + daysInMonth + trailingCount) {
      day = index - leadingBlanks.length - daysInMonth + 1;
      label = '$day';
      isOutMonth = true;
    } else {
      label = '';
    }

    final date = readingDate(DateTime.utc(month.year, month.month, day ?? 1));
    final isToday =
        day == today.day &&
        month.year == today.year &&
        month.month == today.month &&
        !isOutMonth;
    final isSelected = selected == date && !isOutMonth;
    final minutes = (!isOutMonth && day != null)
        ? (_daysByDate[date]?.totalMs ?? 0) ~/ 60000
        : 0;
    final heat = _heatLevel(minutes);
    final bg = isOutMonth && !isToday
        ? Colors.transparent
        : Color.alphaBlend(
            colors.actionPrimary.withValues(
              alpha: [0.0, 0.12, 0.25, 0.4, 0.6][heat],
            ),
            colors.surface,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(
        height:
            36 * math.max(1, MediaQuery.textScalerOf(context).scale(13) / 13),
        child: GtButton.raw(
          key: isOutMonth ? null : ValueKey('statistics-date-$date'),
          onPressed: isOutMonth
              ? null
              : () async {
                  if (_opening) return;
                  setState(() {
                    selected = date;
                  });
                  _opening = true;
                  try {
                    await widget.onDate?.call(date);
                  } finally {
                    if (mounted) _opening = false;
                  }
                },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? Border.all(color: colors.actionPrimary, width: 1.4)
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    color: isOutMonth
                        ? colors.textMuted.withValues(alpha: 0.45)
                        : isToday
                        ? colors.textPrimary
                        : colors.textPrimary,
                    fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (isToday)
                  Text(
                    '今天',
                    style: TextStyle(
                      fontSize: 8.5,
                      height: 1.3,
                      color: colors.actionPrimary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _legendSwatch(int level, String label) {
    return Builder(
      builder: (context) {
        final colors = context.gtColors;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    colors.actionPrimary.withValues(
                      alpha: [0.0, 0.12, 0.25, 0.4, 0.6][level],
                    ),
                    colors.surface,
                  ),
                  borderRadius: BorderRadius.circular(4),
                  border: level == 0
                      ? Border.all(color: colors.borderSubtle)
                      : null,
                ),
              ),
              const SizedBox(width: GtSpacing.s1),
              Text(
                label,
                style: GtText.caption(colors.textSecondary)
                    .copyWith(fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }
}
