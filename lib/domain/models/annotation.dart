/// 标注模型（设计文档 7.1 annotations 表）。
///
/// 书签、高亮、笔记共用同一张表和这一个类型，用 [AnnotationKind] 区分：
/// - 书签：只记 [start] 一个位置（书签不带选区），[quote] 是页首摘录；
/// - 高亮：一段选文 [range]，没有想法文字；
/// - 笔记：一段选文加想法文字 [body]。
///
/// Domain 层只认这个类型：数据库生成的行类型（`AnnotationRow`）不外泄，
/// 换存储或加字段时上层不用跟着改（实现计划 N1）。
library;

import 'locator.dart';

/// 标注类型，取值与数据库 `kind` 列一一对应。
enum AnnotationKind {
  bookmark('bookmark'),
  highlight('highlight'),
  note('note');

  const AnnotationKind(this.code);

  /// 落库与传参用的稳定值
  final String code;

  static AnnotationKind fromCode(String code) => values.firstWhere(
    (kind) => kind.code == code,
    // 未知值按高亮处理：至少还能显示摘录，不会整条读不出来
    orElse: () => AnnotationKind.highlight,
  );
}

/// 高亮与笔记的颜色。
///
/// 存的是**名字**而不是十六进制（设计文档 9.6）：同一份数据在浅色和深色
/// 主题下要映射成不同的底色，写死色值就没法跟着主题走。
/// [label] 是列表里的文字标签，只靠颜色区分对色觉障碍用户不友好。
enum AnnotationColor {
  yellow('yellow', '黄色'),
  blue('blue', '蓝色'),
  green('green', '绿色');

  const AnnotationColor(this.code, this.label);

  final String code;
  final String label;

  /// 未知或空值返回 null（老数据没有颜色，按「文字笔记」展示）。
  static AnnotationColor? fromCode(String? code) {
    if (code == null) return null;
    for (final color in values) {
      if (color.code == code) return color;
    }
    return null;
  }
}

/// 一条标注：书签 / 高亮 / 笔记。
class Annotation {
  const Annotation({
    required this.id,
    required this.bookId,
    required this.kind,
    required this.start,
    this.end,
    this.quote = '',
    this.body = '',
    this.color,
    this.chapterTitle = '',
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String bookId;
  final AnnotationKind kind;

  /// 选文起点；书签的位置也在这里
  final Locator start;

  /// 选文终点（左闭右开）；书签为 null
  final Locator? end;

  /// 摘录原文：高亮与笔记是完整选文，书签是加书签时的页首一段
  final String quote;

  /// 想法正文（kind = note 时有值）
  final String body;

  /// 高亮或笔记的颜色；书签为 null
  final AnnotationColor? color;

  /// 章节标题快照：书被移除后章节索引会一起删掉，
  /// 笔记列表要靠它显示「这条写在哪儿」（设计文档 6.2 删除口径）。
  final String chapterTitle;

  final DateTime createdAt;

  /// 最后修改时间：改了想法或换颜色要能在列表里体现。
  /// 老数据没有这一列，读出来等于 [createdAt]。
  final DateTime updatedAt;

  bool get isBookmark => kind == AnnotationKind.bookmark;
  bool get isHighlight => kind == AnnotationKind.highlight;
  bool get isNote => kind == AnnotationKind.note;

  /// 有没有想法文字。没有的就是纯高亮（列表里按高亮展示）。
  bool get hasBody => body.trim().isNotEmpty;

  /// 键：同一条记录改类型（高亮写想法变笔记）时用它去更新
  String get key => id;

  /// 选文范围；书签没有终点，用起点顶替，方便调用方统一处理
  SelectionRange get range => SelectionRange(start: start, end: end ?? start);

  Annotation copyWith({
    AnnotationKind? kind,
    Locator? start,
    Locator? end,
    String? quote,
    String? body,
    AnnotationColor? color,
    bool clearColor = false,
    String? chapterTitle,
    DateTime? updatedAt,
  }) =>
      Annotation(
        id: id,
        bookId: bookId,
        kind: kind ?? this.kind,
        start: start ?? this.start,
        end: end ?? this.end,
        quote: quote ?? this.quote,
        body: body ?? this.body,
        color: clearColor ? null : (color ?? this.color),
        chapterTitle: chapterTitle ?? this.chapterTitle,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
