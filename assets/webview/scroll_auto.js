// 自动阅读留在浏览器显示帧内，不逐帧跨平台通信。
(function () {
  const host = window.gtScroll;
  const auto = host.auto = {running: false, speed: 24, y: 0, last: null, frame: 0};
  // 只在实际活动状态改变时通知 Flutter，不逐帧发送消息。
  function activity(value) {
    if (auto.advancing === value) return;
    auto.advancing = value;
    window.flutter_inappwebview.callHandler('scrollHost', {type: 'activity',
      request: host.request, generation: auto.generation, advancing: value});
  }
  host.stopAuto = () => {
    activity(false);
    auto.running = false; auto.last = null;
    cancelAnimationFrame(auto.frame);
  };
  host.resetAutoBaseline = () => { auto.y = scrollY; auto.last = null; };
  function tick(now) {
    if (!auto.running) return;
    const delta = auto.last === null ? 0 : now - auto.last;
    auto.last = now;
    if (host.busy || !host.ready || delta > 100) {
      activity(false);
      auto.y = scrollY;
    } else if (delta > 0) {
      const max = Math.max(0, document.documentElement.scrollHeight - innerHeight);
      // 保留不足一个像素的距离，避免浏览器的像素取整把低速滚动吞掉。
      auto.y = Math.min(max, auto.y + auto.speed * delta / 1000);
      const previous = scrollY;
      scrollTo(0, auto.y);
      if (scrollY !== previous) activity(true);
      else if (auto.y >= max) activity(false);
      if (auto.y >= max && host.frames.at(-1)?.meta.index === host.count - 1) {
        host.stopAuto(); host.report();
        window.flutter_inappwebview.callHandler('scrollHost',
          {type: 'end', request: host.request});
        return;
      }
    }
    auto.frame = requestAnimationFrame(tick);
  }
  host.startAuto = (speed, generation) => {
    host.stopAuto(); auto.generation = generation; auto.speed = speed; auto.y = scrollY;
    auto.running = true; auto.frame = requestAnimationFrame(tick);
  };
})();
