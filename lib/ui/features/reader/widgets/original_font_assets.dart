import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../data/services/epub_source_repository.dart';
import '../../../../platform/channels/preset_fonts.dart';
import '../../../../platform/channels/reading_fonts.dart';

bool get _nativeAssets =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// 分页和滚动共用同一资源路径。Android 在 WebView 的资源线程读取 APK，
/// 不再为三个章节各向 Dart 请求、复制一份十几 MiB 的内置字体。
WebViewAssetLoader? originalFontAssetLoader() => !_nativeAssets
    ? null
    : WebViewAssetLoader(
        domain: kEpubSourceHost,
        httpAllowed: false,
        pathHandlers: [AssetsPathHandler(path: PresetFonts.webViewAssetPrefix)],
      );

String originalFontCss(String? family) =>
    ReadingFonts.cssFor(family, nativeAssets: _nativeAssets);

/// 预备实例和正式阅读共用原生设置，接手时不能沿用插件默认的缓存或文件访问。
InAppWebViewSettings originalWebViewSettings({bool scrolling = false}) =>
    InAppWebViewSettings(
      webViewAssetLoader: originalFontAssetLoader(),
      useHybridComposition: false,
      javaScriptEnabled: true,
      javaScriptCanOpenWindowsAutomatically: false,
      supportMultipleWindows: false,
      allowFileAccess: false,
      allowContentAccess: false,
      cacheEnabled: false,
      supportZoom: false,
      transparentBackground: true,
      verticalScrollBarEnabled: false,
      horizontalScrollBarEnabled: false,
      useShouldOverrideUrlLoading: true,
      useShouldInterceptRequest: true,
      disableContextMenu: scrolling,
    );
