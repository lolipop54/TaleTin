import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models/book_completion.dart';
import '../../domain/repositories/book_completion_repository.dart';
import '../database/app_database.dart';

class DriftBookCompletionRepository implements BookCompletionRepository {
  DriftBookCompletionRepository(this.db);
  final AppDatabase db;

  @override
  Future<List<BookCompletion>> load() async =>
    (await db.customSelect('SELECT * FROM book_completions ORDER BY completed_at DESC, id').get())
      .map((r) => BookCompletion(id: r.read('id'), bookId: r.read('book_id'),
        title: r.read('title'), completedAt: DateTime.parse(r.read('completed_at')),
        source: CompletionSource.values.byName(r.read('source')),
        revokedAt: r.readNullable<String>('revoked_at') == null ? null
          : DateTime.parse(r.read('revoked_at')))).toList(growable: false);

  @override
  Future<void> mark(String bookId, String title, CompletionSource source) async {
    await db.customStatement('''INSERT OR IGNORE INTO book_completions
      (id,book_id,title,completed_at,source) VALUES(?,?,?,?,?)''',
      [const Uuid().v4(), bookId, title, DateTime.now().toUtc().toIso8601String(), source.name]);
    db.notifyUpdates({const TableUpdate('book_completions')});
  }

  @override
  Future<void> revoke(String bookId) async {
    await db.customStatement('''UPDATE book_completions SET revoked_at=?
      WHERE book_id=? AND revoked_at IS NULL''',
      [DateTime.now().toUtc().toIso8601String(), bookId]);
    db.notifyUpdates({const TableUpdate('book_completions')});
  }

  @override
  Stream<List<BookCompletion>> watch() => Stream.multi((out) {
    Future<void> pending = Future.value();
    void refresh() {
      pending = pending.then((_) async => out.add(await load()))
        .catchError((Object e, StackTrace s) => out.addError(e,s));
    }
    final sub = db.tableUpdates(const TableUpdateQuery.onTableName('book_completions'))
      .listen((_) => refresh());
    refresh();
    out.onCancel = sub.cancel;
  });
}
