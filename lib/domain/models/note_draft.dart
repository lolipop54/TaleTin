/// 编辑中的笔记草稿（实现计划 N4 与 3.1 节）。
///
/// 草稿与「已保存的笔记」是两回事：写了一半的想法、切后台、被系统杀掉之后
/// 回来还能接着写，但它不算一条笔记（不进列表、不计成就）。
/// 一本书留一份，保存成功或明确放弃后清掉。
library;

import 'locator.dart';

class NoteDraft {
  const NoteDraft({
    required this.range,
    required this.quote,
    required this.body,
    this.chapterTitle = '',
    required this.savedAt,
  });

  /// 已规范化的选区：重启后没有活着的选区，靠它接着保存
  final SelectionRange range;

  /// 这段选文的完整摘录
  final String quote;

  /// 用户正在写的内容
  final String body;

  /// 章节标题快照，保存时一起写进笔记
  final String chapterTitle;

  /// 草稿最后写入时间
  final DateTime savedAt;

  /// 没写任何内容：这种草稿不值得留（打开又原样关掉）
  bool get isEmpty => body.trim().isEmpty;

  NoteDraft copyWith({String? body, DateTime? savedAt}) => NoteDraft(
        range: range,
        quote: quote,
        body: body ?? this.body,
        chapterTitle: chapterTitle,
        savedAt: savedAt ?? this.savedAt,
      );

  Map<String, Object?> toJson() => {
        'start': range.start.toJson(),
        'end': range.end.toJson(),
        'quote': quote,
        'body': body,
        if (chapterTitle.isNotEmpty) 'chapterTitle': chapterTitle,
        'savedAt': savedAt.toUtc().toIso8601String(),
      };

  /// 解析草稿；键缺失或类型不对时返回 null（当作没有草稿）。
  static NoteDraft? fromJson(Map<String, Object?> json) {
    final start = json['start'];
    final end = json['end'];
    if (start is! Map || end is! Map) return null;
    final savedAt = DateTime.tryParse(json['savedAt'] as String? ?? '');
    if (savedAt == null) return null;
    return NoteDraft(
      range: SelectionRange(
        start: Locator.fromJson(start.cast<String, Object?>()),
        end: Locator.fromJson(end.cast<String, Object?>()),
      ),
      quote: json['quote'] as String? ?? '',
      body: json['body'] as String? ?? '',
      chapterTitle: json['chapterTitle'] as String? ?? '',
      savedAt: savedAt.toLocal(),
    );
  }
}
