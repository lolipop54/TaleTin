/* WebView 宿主页内部共享状态与 Dart 通信；不直接暴露给业务侧。 */
(function () {
  'use strict';

  var CHANNEL = 'gtHost';
  // 捕获当前文档的加载标识，旧回调不会冒充新加载。
  var sendToParent = window.__gtSend;
  var internal = window.__gtHost = window.__gtHost || {};

  internal.state = {
    width: 0,          // 一页宽（px），由 Dart 下发
    page: 0,           // 当前页（从 0 开始）
    pages: 1,          // 总页数
    indexComplete: true, // false 时 pages 仅是已证实存在的页范围，不是总页数
    contentWidth: 0,   // 内容总宽（每次量页数时更新，供自检）
    scrollWidth: 0,    // body.scrollWidth（诊断用）
    started: false,    // 是否已完成首次分栏
    margin: 0,         // 一页左右各留多少边距（px），由 Dart 下发
    columnWidth: 0     // 一列的宽度 = 视口宽 - 两侧边距（诊断用）
  };

  /* 文档解析早期 JS 桥可能尚未注入，最多重试约 3 秒。 */
  internal.post = function (type, payload, attempt) {
    var bridge = window.flutter_inappwebview;
    if (sendToParent) {
      var event = Object.assign({ type: type }, payload || {});
      if (sendToParent(event)) return true;
      if ((attempt || 0) < 30) setTimeout(function () {
        internal.post(type, payload, (attempt || 0) + 1);
      }, 100);
      return false;
    }
    if (!bridge || typeof bridge.callHandler !== 'function') {
      if ((attempt || 0) < 30) {
        setTimeout(function () {
          internal.post(type, payload, (attempt || 0) + 1);
        }, 100);
      }
      return false;
    }
    try {
      var message = { type: type };
      if (payload) {
        for (var key in payload) {
          if (Object.prototype.hasOwnProperty.call(payload, key)) {
            message[key] = payload[key];
          }
        }
      }
      bridge.callHandler(CHANNEL, JSON.stringify(message));
      return true;
    } catch (error) {
      // 上报失败不影响阅读。
      return false;
    }
  };
})();
