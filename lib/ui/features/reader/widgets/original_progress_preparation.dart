part of 'original_reader_area.dart';

/// 标准正文尚在后台读取时，用现有离屏槽开始准备用户已经提交的目标。
/// 只由进度跳转入口调用，不猜用户的下一次位置，也不改变当前会话。
extension _OriginalProgressPreparation on _OriginalReaderAreaState {
  void _displayWorkChanged() {
    if (widget.foregroundWork?.value == true) {
      _preload.hold('display-transition');
    } else {
      _preload.release('display-transition');
    }
  }

  void _cancelProgressPreparation() {
    if (!ReaderDeliveryExperiments.originalNavigation ||
        !mounted ||
        _parallelTarget == null) {
      return;
    }
    _updateState(() {
      _parallelTarget = null;
      _preload.requestChapter(null);
      _pruneHosts();
    });
  }

  void _prepareProgressChapter(int index, double fraction) {
    if (!mounted ||
        index == widget.session.chapterIndex ||
        (_hosts.containsKey(index) &&
            (!ReaderDeliveryExperiments.originalNavigation ||
                _parallelTarget?.chapter != index))) {
      return;
    }
    _preload.requestChapter(index);
    _updateState(() {
      _parallelTarget = (chapter: index, fraction: fraction);
      // 远跳不是相邻翻页：不要让邻章的首/末页落位覆盖其精确目标。
      // 只复用空出的物理 iframe，等标准正文提交后才启动首次分页。
      if (ReaderDeliveryExperiments.originalNavigation) {
        _mount(_prev, null);
        _mount(_next, null);
      } else {
        _mount(_next, index);
      }
      _pruneHosts();
    });
  }
}
