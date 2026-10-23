/* 分页外壳：三个固定 iframe，只换角色，不搬动已加载的 DOM 节点。 */
(function () {
  'use strict';
  var slots = [0, 1, 2].map(function (id) {
    return { frame: document.getElementById('chapter-' + id), load: null, chapter: null };
  });
  var current = null, slide = 0, capture = null;
  var pending = [];

  function valid(slot, load) {
    return slots[slot] && slots[slot].load === load;
  }

  // 字体加载、rAF等异步任务属于这一份章节文档。iframe被替换后，浏览器
  // 可能不再结束旧Promise；由仍存在的外壳结束桥接等待，释放跳转遮盖。
  function whileLoaded(slot, load, operation) {
    return new Promise(function (resolve, reject) {
      var request = { slot: slot, load: load, cancel: function () { resolve(null); } };
      pending.push(request);
      function finish(action, value) {
        var index = pending.indexOf(request);
        if (index < 0) return; // 已替换文档的迟到回调不处理新请求。
        pending.splice(index, 1);
        action(value);
      }
      Promise.resolve(operation).then(function (value) {
        finish(resolve, valid(slot, load) ? value : null);
      }, function (error) { finish(reject, error); });
    });
  }

  function cancelReplaced() {
    pending = pending.filter(function (request) {
      if (valid(request.slot, request.load)) return true;
      request.cancel();
      return false;
    });
  }
  function layout() {
    slots.forEach(function (slot, id) {
      var active = slot.load !== null;
      var offset = slot.chapter === current ? 0 : (slot.chapter < current ? -1 : 1);
      slot.frame.style.visibility = active && (capture === null || capture === id) ? 'visible' : 'hidden';
      slot.frame.style.transform = 'translateX(' + (capture === id ? 0 : offset * window.innerWidth + slide) + 'px)';
      slot.frame.style.zIndex = slot.chapter === current ? '1' : '0';
    });
  }
  window.__gtPager = {
    // 与消息通道使用同一槽位/加载号；被替换文档不能读取新章配置。
    initialLayout: function(slot, load) {
      return valid(slot, load) && slots[slot].initialLayout
        ? slots[slot].initialLayout : null;
    },
    // 拖动只更新三个已加载槽的变换；章身份仍由 sync 一次提交。
    shift: function (chapter, dx) {
      if (chapter !== current) return false;
      slide = dx; layout(); return true;
    },
    sync: function (specs, chapter, dx) {
      current = chapter; slide = dx;
      slots.forEach(function (slot, id) {
        var spec = specs.find(function (item) { return item.slot === id; });
        if (!spec) {
          if (slot.load !== null) slot.frame.src = 'about:blank';
          slot.load = null; slot.chapter = null;
        } else {
          slot.chapter = spec.chapter;
          slot.initialLayout = spec.initialLayout || null;
          if (slot.load !== spec.load) {
            slot.load = spec.load;
            slot.frame.src = spec.url;
          }
        }
      });
      cancelReplaced();
      layout();
    },
    run: function (slot, load, script) {
      if (!valid(slot, load)) return null;
      var result = slots[slot].frame.contentWindow.eval(script);
      return result && typeof result.then === 'function'
        ? whileLoaded(slot, load, result) : result;
    },
    turnRendered: async function (slot, load) {
      if (!valid(slot, load)) return false;
      // Dart已等200ms，但繁忙时浏览器可能晚一帧才启动变换。只等阅读器的
      // 正文transform过渡结束，不等待书中可能永久循环的其他动画。
      var body = slots[slot].frame.contentDocument.body;
      var transitions = body ? body.getAnimations().filter(function (animation) {
        return animation.transitionProperty === 'transform';
      }) : [];
      await whileLoaded(slot, load, Promise.all(transitions.map(function (animation) {
        // 重排或换章会取消旧变换；whileLoaded仍校验章节加载号。
        return animation.finished.catch(function () {});
      })));
      return valid(slot, load);
    },
    rendered: async function (slot, load) {
      if (!valid(slot, load)) return false;
      // 初次导航可能刚替换about:blank；即使load编号不变，旧子文档的rAF也会
      // 被浏览器丢弃。使用始终保留的外壳等两帧，实际可读与绘制仍由章节
      // paginated/relocate和Android visual-state、OnDraw共同确认。
      await whileLoaded(slot, load, new Promise(function (resolve) {
        window.requestAnimationFrame(function () { window.requestAnimationFrame(resolve); });
      }));
      return valid(slot, load);
    },
    post: function (source, slot, load, chapter, message) {
      if (!valid(slot, load) || slots[slot].chapter !== chapter ||
          slots[slot].frame.contentWindow !== source) return false;
      var bridge = window.flutter_inappwebview;
      if (!bridge || typeof bridge.callHandler !== 'function') return false;
      bridge.callHandler('gtHost', JSON.stringify({ slot: slot, load: load, chapter: chapter, event: message }));
      return true;
    },
    showCapture: function (slot, load) {
      if (!valid(slot, load)) return false;
      capture = slot; layout(); return true;
    },
    // 同一次调用选中槽位并切到目标页。DOM 同步修改后由 Android
    // visual-state + OnDraw 确认真实画面，不再额外往返等待网页两帧。
    previewCapture: function (slot, load, page) {
      if (!valid(slot, load)) return false;
      capture = slot; layout();
      slots[slot].frame.contentWindow.__gt.previewPage(page);
      return true;
    },
    restore: function () { capture = null; layout(); }
  };
  window.addEventListener('resize', layout);
})();
