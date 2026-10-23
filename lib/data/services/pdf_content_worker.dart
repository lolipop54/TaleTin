part of 'chapter_content_worker.dart';

/// PDFium仍由界面持有；本类只在正文worker内处理索引、JSON和文件缓存。
/// 从start到finish/abort一直保护整书目录，原生补图期间其他worker也不能回收它。
class _PdfContentCache {
  _PdfContentCache(this.library, this.cache, this.epoch);
  final String library, epoch;
  final String? cache;
  final _readers = <String, IndexedChapterReader>{};
  final _preparing = <String, IndexedChapterReader>{};

  Future<Object?> run((String, Object?) command) async {
    final (operation, argument) = command;
    if (operation == 'start') {
      final (key, bookId, chapter) = argument as (String, String, Chapter);
      final directory = p.dirname(chapter.contentPath);
      final readerKey = '$bookId/$directory';
      final reader =
          _readers.remove(readerKey) ??
          IndexedChapterReader.open(
            p.join(library, bookId),
            p.join(library, bookId, directory),
            cacheRoot: cache,
            cacheEpoch: epoch,
          );
      _readers[readerKey] = reader;
      while (_readers.length > 2) {
        final idle = _readers.keys
            .where(
              (k) => !_preparing.containsValue(_readers[k]) && k != readerKey,
            )
            .firstOrNull;
        if (idle == null) break;
        await _readers.remove(idle)!.close();
      }
      await reader.cache!.beginPreparation();
      _preparing[key] = reader;
      try {
        await reader.verifySource();
        final file = reader.cache!.file('chapters/${chapter.id}.json');
        return file.existsSync()
            ? ChapterContent.fromJson(
                (jsonDecode(file.readAsStringSync()) as Map)
                    .cast<String, Object?>(),
              )
            : await reader.read(chapter, (_, _) async => '', textOnly: true);
      } catch (_) {
        _end(key);
        rethrow;
      }
    }
    if (operation == 'missing') {
      final (key, content) = argument as (String, ChapterContent);
      final store = _preparing[key]!.cache!;
      return [
        for (final block in content.blocks)
          if (block.resourcePath case final path?)
            if (!store.file(p.join('assets', path.substring(4))).existsSync())
              (
                path,
                (1600 * content.pdfPage!.blocks[block.id]![2]).round().clamp(
                  200,
                  1600,
                ),
                content.pdfPage!.blocks[block.id]!,
              ),
      ];
    }
    if (operation == 'image') {
      final (key, path, bytes) = argument as (String, String, Uint8List);
      final store = _preparing[key]!.cache!;
      store.write(store.file(p.join('assets', path.substring(4))), bytes);
    } else if (operation == 'finish') {
      final (key, content) = argument as (String, ChapterContent);
      final store = _preparing[key]!.cache!;
      try {
        final file = store.file('chapters/${content.chapterId}.json');
        store.write(file, content.encode());
        store.pin(content.chapterId, [
          file,
          for (final block in content.blocks)
            if (block.resourcePath case final path?)
              store.file(p.join('assets', path.substring(4))),
        ]);
      } finally {
        _end(key);
      }
    } else if (operation == 'abort') {
      _end(argument as String);
    }
    return null;
  }

  void _end(String key) => _preparing.remove(key)?.cache!.endPreparation();

  Future<void> close(String? bookId) async {
    for (final key in _readers.keys.toList()) {
      if (bookId == null || key.startsWith('$bookId/')) {
        await _readers.remove(key)!.close();
      }
    }
  }
}
