import '../../../domain/models/book.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/models/locator.dart';
import '../../../domain/models/speech_unit.dart';
import '../../../domain/repositories/book_repository.dart';
import '../../../domain/repositories/chapter_content_repository.dart';
import '../../../domain/services/listening_source.dart';
import '../../../domain/services/logical_chapter_index.dart';
import '../../../engine/normalization/locator_mapper.dart';
import '../../../engine/normalization/speech_unit_builder.dart';
import '../epub_source_repository.dart';
import 'listening_chapter_targets.dart';
import 'listening_source_worker.dart';

/// 与阅读器复用仓库；每个会话只保留当前文件的语音索引。
class BookListeningSource implements ListeningSource {
  BookListeningSource({
    required this.books,
    required this.contents,
    this.originals,
  });
  final BookRepository books;
  final ChapterContentRepository contents;
  final EpubSourceRepository? originals;

  @override
  Future<ListeningBook> open(String bookId, int contentVersion) async {
    final book = await books.findById(bookId);
    if (book == null ||
        book.status != BookStatus.active ||
        book.contentVersion != contentVersion) {
      throw StateError('书籍或正文版本已变化，请重新打开');
    }
    final chapters = await books.chaptersOf(bookId);
    final toc = await contents.toc(bookId, contentVersion);
    final entries = LogicalChapterIndex.build(
      bookChapters: chapters,
      toc: toc,
    ).chapters.toList();
    entries.sort(
      (a, b) => chapters
          .indexWhere((c) => c.id == a.chapterId)
          .compareTo(chapters.indexWhere((c) => c.id == b.chapterId)),
    );
    return RepositoryListeningBook(
      bookId: bookId,
      version: contentVersion,
      title: book.title,
      files: chapters,
      contents: contents,
      entries: entries,
      originals: originals,
    );
  }
}

class RepositoryListeningBook implements ListeningBook {
  RepositoryListeningBook({
    required this.bookId,
    required this.version,
    required this.title,
    required this.files,
    required this.contents,
    List<LogicalChapter>? entries,
    this.originals,
  }) : _entries =
           entries ??
           [
             for (final file in files)
               LogicalChapter(
                 id: file.id,
                 title: file.title,
                 chapterId: file.id,
               ),
           ];

  final String bookId;
  final int version;
  @override
  final String title;
  final List<Chapter> files;
  final ChapterContentRepository contents;
  final EpubSourceRepository? originals;
  final List<LogicalChapter> _entries;
  final _targets = <String, Future<List<ListeningTarget>>>{};
  List<SpeechUnit>? _index;
  ChapterContent? _content;
  int? _maxLength;
  // 标题与首段可能使用同一位置。仅给本次返回的 next 记下单元下标，
  // 避免换窗口重读标题；用户新定位仍按真实正文位置找起点，不写入数据库。
  Expando<int> _continuations = Expando<int>();
  bool _closed = false;

  @override
  List<LogicalChapter> get chapters => List.unmodifiable(_entries);

  LocatorMapper mapper(String chapterId) => LocatorMapper(
    bookId: bookId,
    contentVersion: version,
    chapterId: chapterId,
  );

  @override
  Future<Locator> chapterStart(String logicalChapterId) async {
    final entry = _entries.firstWhere((entry) => entry.id == logicalChapterId);
    final file = files.firstWhere((file) => file.id == entry.chapterId);
    final content = await contents.chapter(bookId, file, textOnly: true);
    final targets = await _targetsFor(file, content);
    return targets.firstWhere((t) => t.chapter.id == logicalChapterId).start;
  }

  Future<List<ListeningTarget>> _targetsFor(
    Chapter file,
    ChapterContent content,
  ) => _targets.putIfAbsent(file.id, () async {
    final entries = _entries.where((e) => e.chapterId == file.id).toList();
    final targets = await loadListeningTargets(
      bookId: bookId,
      version: version,
      files: files,
      file: file,
      content: content,
      entries: entries,
      originals: originals,
    );
    if (!_closed && entries.isNotEmpty) {
      final first = _entries.indexWhere((e) => e.chapterId == file.id);
      _entries.removeWhere((e) => e.chapterId == file.id);
      _entries.insertAll(
        first,
        uniqueListeningTargets(targets).map((t) => t.chapter),
      );
    }
    return targets;
  });

  @override
  Future<SpeechWindow> window(
    Locator from, {
    required bool sentenceStart,
    required int maxLength,
  }) async {
    if (_closed) throw StateError('听书正文会话已关闭');
    final fileIndex = files.indexWhere((file) => file.id == from.chapterId);
    if (fileIndex < 0) throw StateError('听书位置不属于这本书');
    final file = files[fileIndex];
    var index = _index;
    var content = _content;
    if (content?.chapterId != file.id ||
        _maxLength != maxLength ||
        index == null) {
      content = await contents.chapter(bookId, file, textOnly: true);
      final targets = uniqueListeningTargets(await _targetsFor(file, content));
      var initialId = _entries.first.id;
      for (final entry in _entries) {
        if (files.indexWhere((c) => c.id == entry.chapterId) >= fileIndex) {
          break;
        }
        initialId = entry.id;
      }
      // 大部头单文件切句不阻塞播放命令；过期结果由控制器的 epoch 丢弃。
      index = await buildListeningUnits(
        bookId: bookId,
        version: version,
        content: content,
        targets: targets,
        initialChapterId: initialId,
        maxLength: maxLength,
      );
      if (!_closed) {
        _index = index;
        _content = content;
        _maxLength = maxLength;
        _continuations = Expando<int>();
      }
    }
    final blocks = content!.blocks;
    final ready = index;
    final blockOrder = {for (final (i, block) in blocks.indexed) block.id: i};
    final order = blocks.indexWhere((block) => block.id == from.blockId);
    if (order < 0 && blocks.isNotEmpty && from.blockId.isNotEmpty) {
      throw StateError('听书位置已失效');
    }
    var start =
        _continuations[from] ??
        ready.indexWhere((unit) {
          final unitOrder = blockOrder[unit.startLocator.blockId]!;
          return unitOrder > order ||
              (unitOrder == order &&
                  (unit.endLocator.utf16Offset > from.utf16Offset ||
                      (unit.isChapterTitle &&
                          unit.startLocator.utf16Offset == from.utf16Offset)));
        });
    if (start < 0) start = ready.length;
    if (sentenceStart) {
      while (start > 0 &&
          start < ready.length &&
          ready[start - 1].sentenceId == ready[start].sentenceId) {
        start--;
      }
    }
    final units = ready.sublist(
      start,
      (start + kSpeechUnitWindow).clamp(0, ready.length),
    );
    final after = start + units.length;
    final next = after < ready.length
        ? ready[after].startLocator.copyWith()
        : fileIndex + 1 < files.length
        ? mapper(files[fileIndex + 1].id).chapterStart(const [])
        : null;
    if (next != null && after < ready.length) _continuations[next] = after;
    return SpeechWindow(units, next);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _index = null;
    _content = null;
    _continuations = Expando<int>();
    _targets.clear();
  }
}
