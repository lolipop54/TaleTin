import 'dart:convert';

import '../../domain/models/locator.dart';

const bookmarkTraceEnabled = bool.fromEnvironment('GT_TRACE_BOOKMARK');

/// 书签专项诊断只记录位置与版面数字，不输出正文、摘录、笔记或源文件路径。
void traceBookmark(String stage, Map<String, Object?> details) {
  if (!bookmarkTraceEnabled) return;
  // ignore: avoid_print
  print(
    'GT_BOOKMARK ${jsonEncode({'wallUs': DateTime.now().microsecondsSinceEpoch, 'stage': stage, ...details})}',
  );
}

Map<String, Object?> bookmarkTraceLocator(Locator? locator) => {
  if (locator != null) ...{
    'bookId': locator.bookId,
    'chapterId': locator.chapterId,
    'blockId': locator.blockId,
    'offset': locator.utf16Offset,
    'affinity': locator.affinity.name,
    'contentVersion': locator.contentVersion,
    'needsRelocation': locator.needsRelocation,
  },
};
