import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/repositories/chapter_content_repository.dart';
import 'automatic_reading.dart';

bool isSourceChange(Object? error) =>
    error is ContentFailure && error.code == ContentErrorCode.sourceChanged;

/// 暂停旧会话的操作，更新完成后再恢复；初次开书由会话准备入口处理。
class ReaderSourceChange extends Notifier<bool> {
  ReaderSourceChange(this.bookId);
  final String bookId;
  @override
  bool build() {
    final source = libraryBooksProvider.select(
      (value) => value.value?.where((b) => b.id == bookId).firstOrNull?.status,
    );
    ref.listen(source, (_, status) {
      if (status == BookStatus.sourceChanged) markChanged();
    });
    return false;
  }

  void markChanged() {
    if (state) return;
    state = true;
    ref.read(automaticReadingProvider(bookId).notifier).pause().ignore();
  }

  void complete() => state = false;
}

final readerSourceChangeProvider = NotifierProvider.autoDispose
    .family<ReaderSourceChange, bool, String>(ReaderSourceChange.new);
