part of 'original_body.dart';

/// 本地资源策略与章节框架注入，外壳和章节 iframe 共用。
extension _OriginalBodyResources on _OriginalBodyState {
  /// 所有资源请求的应答。**永远不返回 null**——返回 null 会让 WebView 真的去
  /// 访问网络，书里写的外网地址也一样，那正是要挡掉的东西。
  Future<WebResourceResponse> _intercept(
    InAppWebViewController controller,
    WebResourceRequest request,
  ) async {
    final url = request.url;
    // WebView 自己会要站点图标：给个空响应就行，不计入书的资源统计
    if (url.path == '/favicon.ico') {
      return WebResourceResponse(
        contentType: 'image/x-icon',
        contentEncoding: 'utf-8',
        data: Uint8List(0),
      );
    }
    gtDebugLog('[gt] 请求 ${url.path}');

    if (url.host != kEpubSourceHost) {
      gtDebugLog('[gt] -> 外部域名，已挡下');
      return _notFound();
    }
    final background = ReadingBackgroundTexture.bytesFor(url);
    if (background != null) {
      return WebResourceResponse(
        contentType: background.first == 255 ? 'image/jpeg' : 'image/png',
        data: background,
      );
    }
    if (url.path.startsWith('/__gt_fonts/')) {
      final bytes = await traceTurnStep(
        'font-read chapter=${widget.current}',
        () => ReadingFonts.bytes(url.pathSegments.last),
      );
      traceTurn('font-read chapter=${widget.current} bytes=${bytes?.length}');
      return bytes == null
          ? _notFound()
          : WebResourceResponse(contentType: 'font/ttf', data: bytes);
    }
    if (url.path.startsWith(kFrameworkPathPrefix)) {
      gtDebugLog('[gt] -> 框架资源');
      return _frameworkResource(url.path);
    }

    final resource = await traceTurnStep(
      'book-resource chapter=${widget.current}',
      () => widget.session.resourceFor(url),
    );
    traceTurn(
      'book-resource chapter=${widget.current} bytes=${resource?.bytes.length}',
    );
    if (resource == null) {
      gtDebugLog('[gt] -> 404（条目不存在或越界）');
      return _notFound();
    }

    final entryPath = widget.session.entryPathOf(url);
    if (entryPath != null && widget.session.isChapterEntry(entryPath)) {
      // 章节文档：注入框架样式与脚本后再交出去
      final html = _injectFramework(
        utf8.decode(resource.bytes, allowMalformed: true),
        url,
      );
      gtDebugLog(
        '[gt] -> 章节文档，注入后 ${html.length} 字符；'
        'head 片段：${_headSnippet(html)}',
      );
      return WebResourceResponse(
        contentType: 'text/html',
        contentEncoding: 'utf-8',
        data: Uint8List.fromList(utf8.encode(html)),
      );
    }

    gtDebugLog('[gt] -> ${resource.contentType} ${resource.bytes.length} 字节');
    return WebResourceResponse(
      contentType: resource.contentType,
      contentEncoding: 'utf-8',
      data: resource.bytes,
    );
  }

  /// 注入后的 head 片段（调试用）
  String _headSnippet(String html) {
    final index = html.toLowerCase().indexOf('__gt__');
    if (index < 0) return '（没有找到注入内容！）';
    final start = index - 60;
    return html.substring(
      start < 0 ? 0 : start,
      (index + 80).clamp(0, html.length),
    );
  }

  /// 把框架样式与脚本注入章节文档。
  ///
  /// 插在 `</head>` 之前：样式排在原书样式之后（配合 `!important` 才能稳定覆盖
  /// 主题色），脚本带 `defer`（等文档解析完再执行，不阻塞首屏）。
  ///
  /// **viewport 必须自己声明**：不声明的话 Android WebView 按 980px 的默认布局
  /// 宽度排版（移动端老规矩），分栏宽度与视口对不上，一屏会露出好几列。
  ///
  /// **先隐藏正文**：文档从加载到分栏完成之间会经历几次布局变化（原书样式、
  /// 我们的字号、列宽），直接显示出来就是用户看到的「排版跳一下」。这段
  /// preload 样式让底色先就位、正文隐藏，分栏完成后由 host.js 一次显示；
  /// host.js 里还有兜底定时器，脚本出问题也不会白屏。
  String _frameworkHead(Uri? url) {
    final base = 'https://$kEpubSourceHost$kFrameworkPathPrefix';
    final background = widget.chapters.first.themeColors?['bg'] ?? '#FFFFFF';
    const viewport =
        '<meta name="viewport" content="width=device-width,initial-scale=1,'
        'maximum-scale=1,user-scalable=no"/>';
    final preload =
        '<style id="gt-preload">'
        'html,body{background:$background !important}'
        'body{visibility:hidden !important}'
        // 字体基准仍读取原书计算样式；只在首次配置前不生成整章布局。
        '${ReaderDeliveryExperiments.originalFinalLayout ? 'body{display:none !important}' : ''}'
        '</style>';
    // 地址保留原 EPUB 路径，只添加加载编号；不改变原文档的 DOCTYPE。
    final slot = int.tryParse(url?.queryParameters['gtSlot'] ?? '');
    final load = int.tryParse(url?.queryParameters['gtLoad'] ?? '');
    final chapter = int.tryParse(url?.queryParameters['gtChapter'] ?? '');
    final bridge = url == null
        ? '__GT_NATIVE_BRIDGE__'
        : slot == null || load == null || chapter == null
        ? ''
        : '<script>window.__gtSend=function(event){return parent.__gtPager.post('
              'window,$slot,$load,$chapter,event);};</script>';
    final injection =
        '$viewport$preload$bridge'
        '<script>window.__gtReaderPerf=$readerPerformanceEnabled;'
        'window.__gtRecovery=$readerRecoveryDiagnosticsEnabled;'
        'window.__gtImageDecodeVisible=${OpeningExperiments.visibleImageDecode};</script>'
        '<script>window.__gtDeliveryOriginal=${ReaderDeliveryExperiments.originalWindow};'
        'window.__gtContentTarget=${ReaderDeliveryExperiments.contentTarget};</script>'
        '<script>window.__gtBatchMarkers=${ReaderDeliveryExperiments.originalMarkers};</script>'
        '<script>window.__gtFinalLayout=${ReaderDeliveryExperiments.originalFinalLayout};</script>'
        '<script src="${base}reader_perf.js" defer></script>'
        '${readerTurnDiagnosticsEnabled ? '<script src="${base}reader_turn_diagnostics.js" defer></script>' : ''}'
        '${turnTraceEnabled ? '<script>window.__gtTraceTurn=true;</script>' : ''}'
        '${bookmarkTraceEnabled ? '<script>window.__gtTraceBookmark=true;</script>' : ''}'
        '<link rel="stylesheet" href="${base}host.css"/>'
        '<script src="${base}page_information.js" defer></script>'
        '<script src="${base}tts_range.js" defer></script>'
        '<script src="${base}host_state.js" defer></script>'
        '<script src="${base}host_layout.js" defer></script>'
        '<script src="${base}host_style.js" defer></script>'
        '<script src="${base}host_dom.js" defer></script>'
        '<script src="${base}host_selection.js" defer></script>'
        '<script src="${base}host_index.js" defer></script>'
        '<script src="${base}host_content.js" defer></script>'
        '<script src="${base}host_highlight.js" defer></script>'
        '<script src="${base}host.js" defer></script>';
    return injection;
  }

  String _injectFramework(String html, Uri url) {
    final injection = _frameworkHead(url);
    final index = html.toLowerCase().indexOf('</head>');
    if (index < 0) return injection + html;
    return html.replaceRange(index, index, injection);
  }

  /// 框架资源从 assets 读；名字不合格（含路径分隔符或 `..`）直接 404。
  Future<WebResourceResponse> _frameworkResource(String path) async {
    final name = path.substring(kFrameworkPathPrefix.length);
    if (name.isEmpty || name.contains('/') || name.contains('..')) {
      return _notFound();
    }
    try {
      final data = await rootBundle.load('assets/webview/$name');
      traceTurn('pager asset=$name bytes=${data.lengthInBytes}');
      return WebResourceResponse(
        contentType: name.endsWith('.html')
            ? 'text/html'
            : name.endsWith('.css')
            ? 'text/css'
            : 'application/javascript',
        contentEncoding: 'utf-8',
        data: data.buffer.asUint8List(),
      );
    } on FlutterError {
      return _notFound();
    }
  }

  WebResourceResponse _notFound() => WebResourceResponse(
    contentType: 'text/plain',
    contentEncoding: 'utf-8',
    data: Uint8List(0),
    headers: const {'Content-Type': 'text/plain'},
    statusCode: 404,
    reasonPhrase: 'Not Found',
  );
}
