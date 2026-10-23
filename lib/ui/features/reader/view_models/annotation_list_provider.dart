import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/concurrency/background_compute.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/bookmark.dart';
import '../../../../domain/models/book_document.dart';

typedef NoteListInput = (List<Annotation>, String);
final _notes = FutureProvider.autoDispose
    .family<List<Annotation>, NoteListInput>(
      (ref, input) => backgroundCompute(_filterNotes, input),
    );
final noteListProvider = Provider.autoDispose
    .family<AsyncValue<List<Annotation>>, NoteListInput>((ref, input) {
      if (input.$2.trim().isEmpty) return AsyncData(input.$1);
      var size = 0;
      if (input.$1.length < backgroundListThreshold) {
        for (final note in input.$1) {
          size +=
              note.quote.length + note.body.length + note.chapterTitle.length;
          if (size >= 32768) break;
        }
      }
      return input.$1.length < backgroundListThreshold && size < 32768
          ? AsyncData(_filterNotes(input))
          : ref.watch(_notes(input));
    });
List<Annotation> _filterNotes(NoteListInput input) {
  final keyword = input.$2.trim().toLowerCase();
  return input.$1
      .where(
        (note) => '${note.quote}\n${note.body}\n${note.chapterTitle}'
            .toLowerCase()
            .contains(keyword),
      )
      .toList();
}

typedef BookmarkListInput = (List<Bookmark>, List<Chapter>, String);
typedef BookmarkList = ({List<Bookmark> bookmarks, Map<String, String> titles});
final _bookmarks = FutureProvider.autoDispose
    .family<BookmarkList, BookmarkListInput>(
      (ref, input) => backgroundCompute(_filterBookmarks, input),
    );
final bookmarkListProvider = Provider.autoDispose
    .family<AsyncValue<BookmarkList>, BookmarkListInput>((ref, input) {
      return input.$1.length + input.$2.length < backgroundListThreshold
          ? AsyncData(_filterBookmarks(input))
          : ref.watch(_bookmarks(input));
    });
BookmarkList _filterBookmarks(BookmarkListInput input) {
  final (bookmarks, chapters, query) = input;
  final titles = <String, String>{};
  for (final chapter in chapters) {
    titles.putIfAbsent(chapter.id, () => chapter.title);
  }
  final keyword = query.trim();
  return (
    bookmarks: keyword.isEmpty
        ? bookmarks
        : bookmarks
              .where(
                (b) =>
                    b.quote.contains(keyword) ||
                    (titles[b.locator.chapterId] ?? '').contains(keyword),
              )
              .toList(),
    titles: titles,
  );
}
