part of 'listening_controller.dart';

/// 预设和实际倒计时共用一种策略，停止时只保存时长，不启动平台提醒。
extension _SleepPolicy on ListeningController {
  Future<void> _setSleepPolicy(SleepPolicy policy, {String? bookId, bool restartTimer = false}) async {
    if (policy.kind == SleepPolicyKind.chapterEnd &&
        snapshot.logicalChapterId.isEmpty) {
      throw StateError('章节尚未准备好');
    }
    if (policy.kind == SleepPolicyKind.minutes &&
        (policy.minutes < 1 || policy.minutes > 180)) {
      throw ArgumentError.value(policy.minutes, 'minutes', '须为 1～180 分钟');
    }
    if (policy.kind == SleepPolicyKind.minutes && _sleep == null) {
      throw StateError('定时时钟不可用');
    }
    // 预设绑定当前书，不能误用到另一本正在听的书。
    if (bookId != null && snapshot.bookId != bookId && snapshot.hasSession) {
      await stop();
    }
    // 面板收起明确要求重新计时；暂停／改语速等普通更新仍保留原截止点。
    final restart = restartTimer && snapshot.hasSession && policy.kind == SleepPolicyKind.minutes;
    if (!restart && policy == snapshot.sleepPolicy &&
        (bookId == null || bookId == snapshot.bookId)) {
      return;
    }
    _sleepPending =
        !snapshot.hasSession && policy.kind == SleepPolicyKind.minutes;
    _sleepChapter = policy.kind == SleepPolicyKind.chapterEnd
        ? snapshot.logicalChapterId
        : null;
    _emit(
      snapshot.copyWith(
        bookId: bookId ?? snapshot.bookId,
        sleepPolicy: policy,
        remaining: _sleepPending ? Duration(minutes: policy.minutes) : null,
        notice: null,
      ),
    );
    try {
      await _sleep?.setMinutes(
        !_sleepPending && policy.kind == SleepPolicyKind.minutes
            ? policy.minutes
            : null,
      );
    } catch (error) {
      await _finish(TtsStatus.error, error: '定时设置失败：$error');
    }
  }
}
