import 'app_database.dart';

Future<void> createCompletionSchema(AppDatabase db) async {
  // 不级联删书；标题快照保证历史独立可读。
  await db.customStatement('''CREATE TABLE book_completions (
    id TEXT PRIMARY KEY, book_id TEXT NOT NULL, title TEXT NOT NULL,
    completed_at TEXT NOT NULL, source TEXT NOT NULL, revoked_at TEXT)''');
  await db.customStatement('''CREATE UNIQUE INDEX active_book_completion
    ON book_completions(book_id) WHERE revoked_at IS NULL''');
}
