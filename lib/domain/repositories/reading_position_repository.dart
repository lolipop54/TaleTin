/// 阅读位置仓库（设计文档 7.1 reading_positions 表）。
///
/// 一本书一行：退出阅读页、切后台或换章时写入，下次打开这本书按它恢复。
/// 位置用 `Locator`（章节 + 块 + 块内偏移 + 摘录），与排版无关，
/// 因此改字号、换主题、横竖屏都不会让恢复位置失准。
library;

import '../models/locator.dart';

enum ReadingPositionSource { visual, listening }

/// 一次阅读位置的落库内容：位置 + 全书进度。
class ReadingPosition {
  const ReadingPosition({
    required this.locator,
    required this.progress,
    this.source = ReadingPositionSource.visual,
  });

  final ReadingPositionSource source;

  /// 位置（章节 + 块 + 块内偏移 + 摘录）
  final Locator locator;

  /// 全书进度 0–1，按内容位置算，与排版无关（设计文档 6.3）。
  /// 书架直接显示这个值，因此它逐页变化，而不是只按章边界跳。
  final double progress;
}

abstract interface class ReadingPositionRepository {
  /// 上次读到的位置；没读过或位置已失效时返回 null
  Future<ReadingPosition?> load(String bookId);

  /// 覆盖式写入（一本书一行）
  Future<void> save(ReadingPosition position);
}
