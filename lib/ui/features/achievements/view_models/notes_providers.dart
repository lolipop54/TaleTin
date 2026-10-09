import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/annotation_query.dart';

// 设置页导出仍可按全部/单书选择；单书阅读笔记继续由阅读器管理。
final annotatedBooksProvider = StreamProvider<List<AnnotatedBook>>(
  (ref) => ref.watch(annotationRepositoryProvider).watchAnnotatedBooks(),
);
