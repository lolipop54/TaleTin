import 'app_database.dart';

Future<void> createBookGroupSchema(AppDatabase db) => db.customStatement('''
  CREATE TABLE book_groups (
    id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
    sort_order INTEGER NOT NULL)''');
