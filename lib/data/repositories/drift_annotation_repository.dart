/// [AnnotationRepository] 的 drift 实现（设计文档 7.1）。
///
/// 位置以 JSON 存在 `start_locator_json` / `end_locator_json` 里，因此
/// 「同一位置只留一个书签」这类判断在 Dart 侧做（一本书的标注数量不大，
/// 代价可以忽略）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/annotation.dart';
import '../../domain/models/annotation_query.dart';
import '../../domain/models/book.dart';
import '../../domain/models/bookmark.dart';
import '../../domain/models/locator.dart';
import '../../domain/repositories/annotation_repository.dart';
import '../database/app_database.dart';

class DriftAnnotationRepository implements AnnotationRepository {
  DriftAnnotationRepository(this._db);

  final AppDatabase _db;

  /// 更新来源时一次读取快照，不建立界面订阅；包含书签。
  Future<List<Annotation>> loadForRelocation(String bookId) async {
    final rows = await (_db.select(_db.annotations)
      ..where((t) => t.bookId.equals(bookId))).get();
    return rows.map(_toAnnotation).toList();
  }

  /// kind 取值：书签 / 高亮 / 笔记（与 `AnnotationKind.code` 一致）
  static const String bookmarkKind = 'bookmark';
  static const String highlightKind = 'highlight';
  static const String noteKind = 'note';

  /// 高亮与笔记共用同一个列表，一次查询取两种 kind
  static const List<String> _textKinds = [highlightKind, noteKind];

  static const _uuid = Uuid();

  @override
  Stream<AnnotationPage> watchAnnotationPage(AnnotationQuery filter) {
    final a = _db.annotations;
    final b = _db.books;
    final query = _db.select(a).join([
      innerJoin(b, b.id.equalsExp(a.bookId)),
    ])..where(a.kind.isIn(_textKinds));
    if (filter.bookId != null) query.where(a.bookId.equals(filter.bookId!));
    final keyword = filter.keyword.trim().toLowerCase();
    if (keyword.isNotEmpty) {
      // instr 匹配原字符，用户输入的 %/_ 不会变成 SQL 通配符。
      Expression<bool> contains(Expression<String> text) =>
        FunctionCallExpression<int>('instr', [text.lower(), Variable(keyword)])
          .isBiggerThanValue(0);
      query.where(contains(a.quote) | contains(a.body));
    }
    if (filter.from != null) {
      query.where(a.createdAt.isBiggerOrEqualValue(filter.from!));
    }
    if (filter.until != null) {
      query.where(a.createdAt.isSmallerThanValue(filter.until!));
    }
    query.orderBy([OrderingTerm.desc(a.updatedAt),
      OrderingTerm.desc(a.createdAt), OrderingTerm.asc(a.id)]);
    query.limit(filter.limit + 1);
    return query.watch().map((rows) => AnnotationPage([
      for (final row in rows.take(filter.limit))
        BookAnnotation(_noteBook(row.readTable(b)), _toAnnotation(row.readTable(a))),
    ], rows.length > filter.limit));
  }

  AnnotatedBook _noteBook(BookRow row) => AnnotatedBook(
    row.id, row.title, BookStatus.fromCode(row.status));

  @override
  Stream<List<AnnotatedBook>> watchAnnotatedBooks() {
    final a = _db.annotations;
    final b = _db.books;
    final query = _db.selectOnly(b, distinct: true)
      ..addColumns([b.id, b.title, b.status])
      ..join([innerJoin(a, a.bookId.equalsExp(b.id))])
      ..where(a.kind.isIn(_textKinds))
      ..orderBy([OrderingTerm.asc(b.title), OrderingTerm.asc(b.id)]);
    return query.watch().map((rows) => [for (final row in rows)
      AnnotatedBook(row.read(b.id)!, row.read(b.title)!,
        BookStatus.fromCode(row.read(b.status)!))]);
  }

  @override
  Stream<int> watchAnnotationCount() {
    final a = _db.annotations;
    final count = a.id.count();
    final query = _db.selectOnly(a)..addColumns([count])
      ..where(a.kind.isIn(_textKinds));
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  @override
  Stream<List<Bookmark>> watchBookmarks(String bookId) {
    final query = _db.select(_db.annotations)
      ..where((t) => t.bookId.equals(bookId) & t.kind.equals(bookmarkKind))
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    return query.watch().map(
          (rows) => [for (final row in rows) _toBookmark(row)],
        );
  }

  @override
  Future<String> addBookmark({
    required Locator locator,
    required String quote,
  }) async {
    final rows = await (_db.select(_db.annotations)
          ..where((t) =>
              t.bookId.equals(locator.bookId) & t.kind.equals(bookmarkKind)))
        .get();
    for (final row in rows) {
      final existing = _toBookmark(row);
      // 同一页首再加一次不重复建：返回已有书签
      if (!existing.locator.needsRelocation && existing.locator.chapterId == locator.chapterId &&
          existing.locator.blockId == locator.blockId &&
          existing.locator.utf16Offset == locator.utf16Offset) {
        return existing.id;
      }
    }

    final id = _uuid.v4();
    await _db.into(_db.annotations).insert(
          AnnotationsCompanion.insert(
            id: id,
            bookId: locator.bookId,
            kind: bookmarkKind,
            startLocatorJson: jsonEncode(locator.toJson()),
            quote: Value(quote),
            createdAt: DateTime.now().toUtc(),
          ),
        );
    return id;
  }

  @override
  Future<void> removeBookmark(String id) async {
    await (_db.delete(_db.annotations)..where((t) => t.id.equals(id))).go();
  }

  @override
  Stream<List<Annotation>> watchAnnotations(String bookId) {
    final query = _db.select(_db.annotations)
      ..where((t) => t.bookId.equals(bookId) & t.kind.isIn(_textKinds))
      // 最近改动的在前：刚写完想法的条目要能立刻在列表顶部看到。
      // 同时间的按创建时间兜底，保证次序稳定不跳动。
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
    return query.watch().map(
          (rows) => [for (final row in rows) _toAnnotation(row)],
        );
  }

  @override
  Future<Annotation?> findByRange(String bookId, SelectionRange range) async {
    final rows = await (_db.select(_db.annotations)
          ..where((t) => t.bookId.equals(bookId) & t.kind.isIn(_textKinds)))
        .get();
    for (final row in rows) {
      final annotation = _toAnnotation(row);
      if (!annotation.start.needsRelocation && annotation.end?.needsRelocation != true &&
          sameSelectionRange(annotation.range, range)) { return annotation; }
    }
    return null;
  }

  @override
  Future<String> saveAnnotation({
    String? id,
    required String bookId,
    required AnnotationKind kind,
    required SelectionRange range,
    required String quote,
    String body = '',
    AnnotationColor? color,
    String chapterTitle = '',
  }) async {
    // 颜色与类型要对得上：高亮总有个底色，笔记可以先不选颜色
    final resolvedColor = kind == AnnotationKind.highlight
        ? (color ?? AnnotationColor.yellow)
        : color;
    // 没给 id 时先看同一选区有没有记录：有就改它，不新建重复记录。
    // 判断只看位置，不看摘录文字（同一段话在书里可能出现多次）。
    final targetId = id ?? (await findByRange(bookId, range))?.id;
    final rowId = targetId ?? _uuid.v4();
    final now = DateTime.now().toUtc();
    final values = AnnotationsCompanion(
      id: Value(rowId),
      bookId: Value(bookId),
      kind: Value(kind.code),
      startLocatorJson: Value(jsonEncode(range.start.toJson())),
      endLocatorJson: Value(jsonEncode(range.end.toJson())),
      quote: Value(quote),
      body: Value(body),
      colorToken: Value(resolvedColor?.code),
      chapterTitle: Value(chapterTitle),
      updatedAt: Value(now),
    );

    if (targetId == null) {
      await _db.into(_db.annotations).insert(
            values.copyWith(createdAt: Value(now)),
          );
      return rowId;
    }
    // 改已有那条：写不进任何一行时说明记录已被删掉，按新建补回，
    // 避免用户刚写的想法随一条并发删除一起丢掉
    final updated = await (_db.update(_db.annotations)
          ..where((t) => t.id.equals(targetId)))
        .write(values);
    if (updated == 0) {
      await _db.into(_db.annotations).insert(
            values.copyWith(createdAt: Value(now)),
          );
    }
    return rowId;
  }

  @override
  Future<void> deleteAnnotation(String id) async {
    await (_db.delete(_db.annotations)..where((t) => t.id.equals(id))).go();
  }

  Bookmark _toBookmark(AnnotationRow row) => Bookmark(
        id: row.id,
        locator: _decodeLocator(row.startLocatorJson),
        quote: row.quote,
        createdAt: row.createdAt,
      );

  /// 数据库行 → 领域模型。位置 JSON 坏掉时给空位置：列表里仍看得到摘录，
  /// 点它不会有反应，不会因为一条坏数据让整个笔记页打不开。
  Annotation _toAnnotation(AnnotationRow row) => Annotation(
        id: row.id,
        bookId: row.bookId,
        kind: AnnotationKind.fromCode(row.kind),
        start: _decodeLocator(row.startLocatorJson),
        end: row.endLocatorJson == null
            ? null
            : _decodeLocator(row.endLocatorJson!),
        quote: row.quote,
        body: row.body,
        color: AnnotationColor.fromCode(row.colorToken),
        chapterTitle: row.chapterTitle,
        createdAt: row.createdAt,
        // v3 老行没有修改时间，按创建时间算（模型自己兜底）
        updatedAt: row.updatedAt,
      );

  /// 位置 JSON 坏掉时给一个空位置：列表里仍能看到书签，点它不会有反应
  Locator _decodeLocator(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, Object?>) return Locator.fromJson(decoded);
    } on FormatException {
      // 落到下面的兜底
    }
    return const Locator(
      bookId: '',
      contentVersion: 1,
      chapterId: '',
      blockId: '',
      utf16Offset: 0,
    );
  }
}
