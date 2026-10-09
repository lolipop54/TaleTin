enum CompletionSource { manual, endConfirm }

/// 完成记录独立于阅读位置；撤销保留历史，不能靠 100% 进度推断。
class BookCompletion {
  const BookCompletion({required this.id, required this.bookId,
    required this.title, required this.completedAt, required this.source,
    this.revokedAt});
  final String id, bookId, title;
  final DateTime completedAt;
  final CompletionSource source;
  final DateTime? revokedAt;
  bool get active => revokedAt == null;
}
