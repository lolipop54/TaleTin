import '../../core/concurrency/background_compute.dart';
import '../../domain/models/annotation.dart';
import '../../domain/models/bookmark.dart';
import '../../domain/models/locator.dart';
import '../database/app_database.dart';
import '../mappers/annotation_mapper.dart';

Future<List<Annotation>> decodeAnnotations(List<AnnotationRow> rows) =>
    backgroundCompute(
      _annotations,
      rows,
      enabled: rows.length >= backgroundListThreshold,
    );
List<Annotation> _annotations(List<AnnotationRow> rows) =>
    rows.map(annotationFromRow).toList();
Future<List<Bookmark>> decodeBookmarks(List<AnnotationRow> rows) =>
    backgroundCompute(
      _bookmarks,
      rows,
      enabled: rows.length >= backgroundListThreshold,
    );
List<Bookmark> _bookmarks(List<AnnotationRow> rows) =>
    rows.map(bookmarkFromRow).toList();

Future<String?> findBookmarkInRows(List<AnnotationRow> rows, Locator point) =>
    backgroundCompute(_findBookmark, (
      rows,
      point,
    ), enabled: rows.length >= backgroundListThreshold);
String? _findBookmark((List<AnnotationRow>, Locator) input) {
  for (final row in input.$1) {
    final bookmark = bookmarkFromRow(row);
    if (bookmark.isAt(input.$2)) return bookmark.id;
  }
  return null;
}

Future<Annotation?> findAnnotationInRows(
  List<AnnotationRow> rows,
  SelectionRange range,
) => backgroundCompute(_findAnnotation, (
  rows,
  range,
), enabled: rows.length >= backgroundListThreshold);
Annotation? _findAnnotation((List<AnnotationRow>, SelectionRange) input) {
  for (final row in input.$1) {
    final note = annotationFromRow(row);
    if (!note.start.needsRelocation &&
        note.end?.needsRelocation != true &&
        sameSelectionRange(note.range, input.$2)) {
      return note;
    }
  }
  return null;
}
