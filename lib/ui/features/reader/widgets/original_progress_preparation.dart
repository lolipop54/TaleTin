part of 'original_reader_area.dart';

/// 标准正文尚在后台读取时，用现有离屏槽开始准备用户已经提交的目标。
/// 只由进度跳转入口调用，不猜用户的下一次位置，也不改变当前会话。
extension _OriginalProgressPreparation on _OriginalReaderAreaState {
  void _prepareProgressChapter(int index, double fraction) {
    if (!mounted ||
        index == widget.session.chapterIndex ||
        _hosts.containsKey(index)) {
      return;
    }
    _preload.requestChapter(index);
    _updateState(() {
      _parallelTarget = (chapter: index, fraction: fraction);
      _mount(_next, index);
      _pruneHosts();
    });
  }
}
