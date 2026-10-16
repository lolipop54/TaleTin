import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../data/services/epub_source_repository.dart';
import '../../../../platform/channels/reading_fonts.dart';
import '../../../../core/diagnostics/opening_experiments.dart';
import 'reader_performance.dart';
import 'original_font_assets.dart';

class ScrollHostAssets {
  ScrollHostAssets(
    this.script,
    this.styleScript,
    this.css,
    this.autoScript,
    this.selectionScript,
  );
  final String script, styleScript, css, autoScript, selectionScript;
  static Future<ScrollHostAssets> load() async => ScrollHostAssets(
    '${await rootBundle.loadString('assets/webview/reader_perf.js')}\n'
    '${await rootBundle.loadString('assets/webview/scroll_anchor.js')}\n'
    '${await rootBundle.loadString('assets/webview/scroll_host.js')}',
    await rootBundle.loadString('assets/webview/host_style.js'),
    await rootBundle.loadString('assets/webview/host.css'),
    await rootBundle.loadString('assets/webview/scroll_auto.js'),
    await rootBundle.loadString('assets/webview/scroll_selection.js'),
  );

  String get html =>
      '<!doctype html><html><head>'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<style>html,body{margin:0;padding:0;overflow-x:hidden;overflow-anchor:none}'
      '#content{display:flex;flex-direction:column}'
      '::-webkit-scrollbar{width:0;height:0}'
      'iframe{display:block;width:100%;border:0;flex-shrink:0}</style></head>'
      '<body><div id="content"></div><script>'
      'window.__gtReaderPerf=$readerPerformanceEnabled;'
      'window.__gtImageDecodeVisible=${OpeningExperiments.visibleImageDecode};'
      'window.gtStyleSource=${jsonEncode(styleScript)};'
      'window.gtBaseCss=${jsonEncode(css)};'
      '$script\n$autoScript\n$selectionScript</script></body></html>';
}

/// 一个固定大小 WebView，章内只保留净化原文；外网请求一律本地 404。
class OriginalScrollWebView extends StatelessWidget {
  const OriginalScrollWebView({
    super.key,
    required this.source,
    required this.assets,
    required this.onController,
    required this.onLoaded,
    required this.onMessage,
    this.preparedView,
  });
  final EpubSourceSession source;
  final HeadlessInAppWebView? preparedView;
  final ScrollHostAssets assets;
  final ValueChanged<InAppWebViewController> onController;
  final VoidCallback onLoaded;
  final Future<Object?> Function(Map<String, dynamic>) onMessage;

  @override
  Widget build(BuildContext context) => InAppWebView(
    headlessWebView: preparedView,
    initialUrlRequest: URLRequest(
      url: WebUri('https://$kEpubSourceHost/__gt__/scroll'),
    ),
    initialSettings: originalWebViewSettings(scrolling: true),
    onWebViewCreated: (controller) async {
      onController(controller);
      controller.addJavaScriptHandler(
        handlerName: 'scrollHost',
        callback: (args) async {
          if (args.isEmpty || args.first is! Map) return null;
          return onMessage(Map<String, dynamic>.from(args.first as Map));
        },
      );
      if (preparedView != null) {
        await controller.setSettings(
          settings: originalWebViewSettings(scrolling: true),
        );
        await controller.loadUrl(
          urlRequest: URLRequest(
            url: WebUri('https://$kEpubSourceHost/__gt__/scroll'),
          ),
        );
      }
    },
    onLoadStop: (_, url) {
      if (url?.host == kEpubSourceHost && url?.path == '/__gt__/scroll') {
        onLoaded();
      }
    },
    onConsoleMessage: (_, message) =>
        debugPrint('[scroll web] ${message.message}'),
    shouldOverrideUrlLoading: (_, action) async {
      final url = action.request.url;
      // 允许阅读器自己的宿主及子框架导航，资源仍由本地拦截器回答。
      if (url?.host == kEpubSourceHost &&
          (url?.path == '/__gt__/scroll' || action.isForMainFrame == false)) {
        return NavigationActionPolicy.ALLOW;
      }
      return NavigationActionPolicy.CANCEL;
    },
    shouldInterceptRequest: (_, request) async {
      final url = request.url;
      if (url.host == kEpubSourceHost && url.path == '/__gt__/scroll') {
        return WebResourceResponse(
          contentType: 'text/html',
          contentEncoding: 'utf-8',
          data: Uint8List.fromList(utf8.encode(assets.html)),
        );
      }
      if (url.host == kEpubSourceHost && url.path.startsWith('/__gt_fonts/')) {
        final bytes = await ReadingFonts.bytes(url.pathSegments.last);
        if (bytes != null) {
          return WebResourceResponse(contentType: 'font/ttf', data: bytes);
        }
      }
      final resource = await source.resourceFor(url);
      if (resource != null) {
        return WebResourceResponse(
          contentType: resource.contentType.split(';').first,
          contentEncoding: 'utf-8',
          data: resource.bytes,
        );
      }
      return WebResourceResponse(
        contentType: 'text/plain',
        data: Uint8List(0),
        statusCode: 404,
        reasonPhrase: 'Not Found',
      );
    },
  );
}
