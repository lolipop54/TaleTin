import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/source_book_providers.dart';
import '../../../../data/services/annotation_locator_service.dart';
import '../../../../domain/models/annotation.dart';

final annotationLocatorProvider = Provider<AnnotationLocatorService>(
  (ref) => AnnotationLocatorService(
    ref.watch(bookRepositoryProvider),
    ref.watch(chapterContentRepositoryProvider),
  ),
);

/// 唯一定位成功后才更新旧锚点，保留记录 ID、摘录、想法与创建时间。
final prepareAnnotationProvider =
    Provider<Future<Annotation> Function(Annotation)>((ref) =>
      ref.watch(prepareSavedAnnotationProvider));

/// 跨书笔记先解析位置，再发送一次性打开请求；阅读器首屏直接使用目标锚点。
final annotationOpeningProvider =
    NotifierProvider<AnnotationOpening, Annotation?>(AnnotationOpening.new);

class AnnotationOpening extends Notifier<Annotation?> {
  @override
  Annotation? build() => null;
  void open(Annotation note) => state = note;
  Annotation? take(String bookId) {
    final note = state;
    if (note?.bookId != bookId) return null;
    state = null;
    return note;
  }
}
