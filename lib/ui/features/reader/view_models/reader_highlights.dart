import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/annotation.dart';
import 'book_search_navigation.dart';
import 'reader_session_view_model.dart';

/// 临时搜索高亮与持久标注一起计算矩形，数据库查询和编辑仍只读 annotationsProvider。
final readerHighlightsProvider = Provider.autoDispose
    .family<List<Annotation>, String>((ref, bookId) {
      final marks =
          ref.watch(annotationsProvider(bookId)).value ?? const <Annotation>[];
      final search = ref.watch(bookSearchNavigationProvider(bookId)).highlight;
      return [...marks.where((m) => !m.start.needsRelocation &&
        m.end?.needsRelocation != true), ?search];
    });
