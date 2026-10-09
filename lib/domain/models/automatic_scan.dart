/// 扫描只提交完整的一页；页标识包含正文版本和版面，不能跨重排续扫。
enum ScanPhase { waiting, running, paused, committing, completed, failed }

typedef ScanPage = ({String bookId, int contentVersion, Object layout, Object page});

class AutomaticScan {
  AutomaticScan(this.current);
  final ScanPage current;
  ScanPage? target;
  ScanPhase phase = ScanPhase.waiting;
  double progress = 0;
  Duration? _last;
  int _version = 0;
  int get version => _version;
  bool accepts(int version) => version == _version;

  int prepare() {
    phase = ScanPhase.waiting;
    _last = null;
    return ++_version;
  }

  bool prepared(int version, ScanPage? next) {
    if (!accepts(version)) return false;
    assert(next == null || (next.bookId == current.bookId &&
        next.contentVersion == current.contentVersion && next.layout == current.layout));
    target = next;
    phase = ScanPhase.running;
    _last = null;
    return true;
  }

  void pause() {
    if (phase == ScanPhase.running || phase == ScanPhase.waiting) {
      ++_version; phase = ScanPhase.paused; _last = null;
    }
  }

  void resume() { phase = ScanPhase.running; _last = null; }

  /// 每帧使用有效时间，超过 100ms 的长帧不补扫。耗时改变不重置进度。
  bool advance(Duration elapsed, double seconds) {
    if (phase != ScanPhase.running) return false;
    final last = _last;
    _last = elapsed;
    if (last == null) return false;
    final micros = (elapsed - last).inMicroseconds;
    if (micros <= 0 || micros > 100000) return false;
    progress = (progress + micros / (seconds * 1000000)).clamp(0.0, 1.0);
    if (progress < 1) return false;
    phase = ScanPhase.committing;
    return true;
  }

  void complete() { phase = ScanPhase.completed; _last = null; }
  void fail() { ++_version; phase = ScanPhase.failed; _last = null; }
  void invalidate() { ++_version; phase = ScanPhase.paused; _last = null; }
}
