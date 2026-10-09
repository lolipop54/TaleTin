/* 分页外壳：三个固定 iframe，只换角色，不搬动已加载的 DOM 节点。 */
(function () {
  'use strict';
  var slots = [0, 1, 2].map(function (id) {
    return { frame: document.getElementById('chapter-' + id), load: null, chapter: null };
  });
  var current = null, slide = 0, capture = null;

  function valid(slot, load) {
    return slots[slot] && slots[slot].load === load;
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
          if (slot.load !== spec.load) {
            slot.load = spec.load;
            slot.frame.src = spec.url;
          }
        }
      });
      layout();
    },
    run: function (slot, load, script) {
      if (!valid(slot, load)) return null;
      return slots[slot].frame.contentWindow.eval(script);
    },
    rendered: async function (slot, load) {
      if (!valid(slot, load)) return false;
      var child = slots[slot].frame.contentWindow;
      await new Promise(function (resolve) {
        child.requestAnimationFrame(function () { child.requestAnimationFrame(resolve); });
      });
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
