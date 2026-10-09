part of 'listening_controller.dart';

/// 下一窗口提前读取；共享同一任务，防止读完回调和预取重复添加正文。
extension _ListeningWindowPreparation on ListeningController {
  Future<void> _fillWindow(int epoch) {
    if (_windowLoad != null && _windowEpoch == epoch) return _windowLoad!;
    _windowEpoch = epoch;
    final task = _loadWindow(epoch);
    _windowLoad = task;
    return task.whenComplete(() {
      if (identical(_windowLoad, task)) _windowLoad = null;
    });
  }

  Future<void> _loadWindow(int epoch) async {
    // 空白/纯图片文件只向后走；每次读取后核对会话，不能让旧请求提交语音。
    while (_current(epoch) && _window.isEmpty && _next != null) {
      final page = await _book!.window(
        _next!,
        sentenceStart: _nextSentenceStart,
        maxLength: _maxLength,
      );
      if (!_current(epoch)) return;
      final units = [...page.units];
      // 页首可能在长句中间。精确开始时裁去页首之前的文字，不能倒退到上一页。
      if (!_nextSentenceStart && units.isNotEmpty) {
        final split = splitSpeechUnitAtPage(units.first, [_next!]);
        if (split.tail case final tail?) units[0] = tail;
      }
      _window.addAll(units);
      _next = page.next;
      _nextSentenceStart = false;
    }
  }
}
