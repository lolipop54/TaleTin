import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/services/book_source_path.dart';
import '../../data/services/source_position_resolver.dart';
import '../../data/services/refresh_saved_annotations.dart';
import '../../domain/use_cases/prepare_source_book.dart';
import '../../domain/models/book.dart';
import '../../domain/models/annotation.dart';
import '../../domain/use_cases/import_books.dart';
import 'app_providers.dart';
import '../../core/io/source_fingerprint.dart';
import '../../core/diagnostics/reader_work_trace.dart';
import '../../core/diagnostics/position_experiments.dart';
import '../../engine/normalization/source_position_cache.dart';

final prepareSourceBookProvider = Provider<PrepareSourceBook>((ref) {
  final root = ref.watch(libraryRootPathProvider);
  final manifests = <String, (String, Future<bool>)>{};
  return PrepareSourceBook(
    ref.watch(bookRepositoryProvider),
    ref.watch(importBooksProvider),
    (book) async =>
        book.localSourcePath ??
        bookSourcePath(p.join(root, book.id), book.format.code),
    needsPreparation: (book) => _legacyNeedsPreparation(
      p.join(
        root,
        book.id,
        'content',
        '${book.contentVersion}',
        'manifest.json',
      ),
      manifests,
    ),
    txtChoice: (book) async {
      if (book.format != BookFormat.txt) return null;
      final options = File(
        p.join(
          root,
          book.id,
          'content',
          '${book.contentVersion}',
          'txt.options',
        ),
      );
      if (!await options.exists()) return null;
      final value = jsonDecode(await options.readAsString()) as Map;
      return TxtImportChoice(
        charset: value['charset'] as String?,
        chapterPattern: value['chapterPattern'] as String?,
        forceSectionFallback: value['forceSectionFallback'] == true,
      );
    },
  );
});

final prepareSavedAnnotationProvider =
    Provider<Future<Annotation> Function(Annotation)>((ref) {
      final prepare = ref.watch(prepareSourceReadingProvider);
      final db = ref.watch(appDatabaseProvider);
      final books = ref.watch(bookRepositoryProvider);
      final contents = ref.watch(chapterContentRepositoryProvider);
      return (note) async {
        await prepare(note.bookId);
        return refreshSavedAnnotation(db, books, contents, note,
          resolver: ref.read(sourcePositionResolverProvider));
      };
    });

// 老 JSON 没有可信来源摘要。首次打开重新建立索引，并核对旧位置，不能猜测相同。
Future<bool> _legacyNeedsPreparation(
  String path,
  Map<String, (String, Future<bool>)> cache,
) async {
  final stat = await File(path).stat();
  if (stat.type != FileSystemEntityType.file) return false;
  final stamp = sourceFingerprint(stat);
  if (cache[path]?.$1 == stamp) return cache[path]!.$2;
  final read = Isolate.run(() {
    final manifest = File(path);
    if (!manifest.existsSync()) return false;
    return (jsonDecode(manifest.readAsStringSync()) as Map)['sourceIndex'] ==
        null;
  });
  cache[path] = (stamp, read);
  return read;
}

final sourcePositionResolverProvider = Provider<SourcePositionResolver>((ref) {
  final contents = ref.watch(chapterContentRepositoryProvider);
  final books = ref.watch(bookRepositoryProvider);
  final root = ref.watch(libraryRootPathProvider);
  return SourcePositionResolver(
    contents,
    loadMatches: !PositionExperiments.optimizedFlow ? null : (id, chapters) async =>
      chapters.isEmpty ? {} : SourcePositionCache.read(
        p.dirname(contents.chapterAbsolutePath(id, chapters.first))),
    saveMatches: !PositionExperiments.optimizedFlow ? null : (id, chapters, matches) async {
      if (chapters.isEmpty) return;
      SourcePositionCache.write(p.dirname(contents.chapterAbsolutePath(id, chapters.first)), matches);
    },
    sourceSignature: (id, chapters) async {
      final book = await books.findById(id);
      if (book == null || chapters.isEmpty) return '';
      final source =
          book.localSourcePath ??
          bookSourcePath(p.join(root, id), book.format.code);
      final manifest = File(
        p.join(
          p.dirname(contents.chapterAbsolutePath(id, chapters.first)),
          'manifest.json',
        ),
      );
      return '${sourceFingerprint(await File(source).stat())}:${sourceFingerprint(await manifest.stat())}';
    },
  );
});

/// 由开书/刷新命令显式调用，Provider build 只组装依赖，不执行写入。
final prepareSourceReadingProvider = Provider<Future<Book> Function(String)>((
  ref,
) {
  final prepare = ref.watch(prepareSourceBookProvider);
  final db = ref.watch(appDatabaseProvider);
  final books = ref.watch(bookRepositoryProvider);
  final contents = ref.watch(chapterContentRepositoryProvider);
  final pending = <String, Future<Book>>{};
  final resolver = ref.watch(sourcePositionResolverProvider);
  Future<Book> run(String id) async {
    final book = await traceReaderWork(
      'source.prepare-or-reuse',
      () => prepare(id),
      {'bookId': id},
    );
    if (book.status == BookStatus.active) {
      await traceReaderWork(
        'source.restore-saved-locations',
        () => refreshSavedAnnotations(
          db,
          books,
          contents,
          id,
          resolver: resolver,
        ),
        {'bookId': id},
      );
    }
    return book;
  }

  return (id) => pending.putIfAbsent(
    id,
    () => run(id).whenComplete(() {
      pending.remove(id);
    }),
  );
});
