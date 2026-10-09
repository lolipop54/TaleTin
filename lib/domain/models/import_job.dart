/// 导入队列与导入任务的领域模型。
library;

import '../../core/errors/import_error.dart';
import 'dart:typed_data';

/// 单本文件的导入阶段，直接决定导入队列右侧状态区显示什么。
enum ImportStage {
  /// 已选中，等待前一本完成
  waiting('waiting'),
  copying('copying'),
  parsing('parsing'),
  committing('committing'),
  done('done'),

  /// 与书架已有书籍重复，跳过（可打开已有书籍）
  duplicate('duplicate'),
  failed('failed'),
  cancelled('cancelled');

  const ImportStage(this.code);
  final String code;

  bool get isFinished =>
      this == ImportStage.done ||
      this == ImportStage.duplicate ||
      this == ImportStage.failed ||
      this == ImportStage.cancelled;
}

/// 导入进度事件：一次导入过程中按阶段推送。
class ImportProgress {
  const ImportProgress({
    required this.key,
    required this.stage,
    this.copiedBytes = 0,
    this.totalBytes,
    this.fraction,
    this.bookId,
    this.failure,
    this.note,
    this.coverBytes,
  });

  /// 文件唯一标识（当前用 SAF URI），用于界面定位队列条目
  final String key;
  final ImportStage stage;

  /// 已复制字节，仅 copying 阶段有意义
  final int copiedBytes;

  /// 源文件大小；未知时为 null，界面显示不定进度
  final int? totalBytes;

  /// 解析阶段进度 0–1；null 表示不定进度
  final double? fraction;

  /// 提交完成后可见的书籍 ID（done / duplicate 时有值）
  final String? bookId;

  final ImportFailure? failure;

  /// 非致命提示，例如「文件容器不完全符合 EPUB 规范」
  final String? note;
  final Uint8List? coverBytes;

  /// 复制进度 0–1；大小未知时为 null（不定进度）
  double? get copyFraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (copiedBytes / total).clamp(0.0, 1.0);
  }
}

/// 取消信号：可取消整批，也可只取消某一本。
///
/// 导入流水线在每个阶段边界检查一次，避免取消后继续写文件或提交事务。
class CancelToken {
  bool _all = false;
  final Set<String> _keys = <String>{};

  void cancelAll() => _all = true;

  void cancel(String key) => _keys.add(key);

  /// 查询是否已取消；[key] 为空表示只判断整批取消。
  bool isCancelled([String? key]) =>
      _all || (key != null && _keys.contains(key));

  /// 某一条是否被单独取消过（用于把结果标记为 cancelled 而不是 failed）
  bool isCancelledIndividually(String key) => _keys.contains(key);

  void reset() {
    _all = false;
    _keys.clear();
  }
}
