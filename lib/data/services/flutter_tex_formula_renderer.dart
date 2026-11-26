import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tex/flutter_tex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../../engine/layout/math_formula.dart';
import '../../engine/layout/math_typesetting.dart';
import '../../platform/channels/windows_app_storage.dart';
import 'formula_svg.dart';

/// 复用 flutter_tex 随包提供的 MathJax；阅读器只接收矢量和尺寸。
/// 转换发生在页面准备阶段，普通章节不会启动公式服务。
class FlutterTexFormulaRenderer implements FormulaRenderer {
  Future<void>? _starting;
  Future<InAppWebViewController>? _windows;
  final _pending = <String, Future<RenderedFormula>>{};

  @override
  Future<RenderedFormula> render(String xml) {
    final key = sha256
        .convert(utf8.encode('${MathTypesetting.revision}|$xml'))
        .toString();
    return _pending.putIfAbsent(
      key,
      () => _render(key, xml).whenComplete(() {
        // whenComplete 不能返回表中的 Future，否则它会等待自己而永不完成。
        _pending.remove(key);
      }),
    );
  }

  Future<RenderedFormula> _render(String key, String xml) async {
    final root = MathTypesetting.cacheRoot ??=
        '${(await getTemporaryDirectory()).path}/formula-${MathTypesetting.revision}';
    await Directory(root).create(recursive: true);
    final file = File('$root/$key.svg');
    String svg;
    if (await file.exists()) {
      svg = await file.readAsString();
    } else {
      svg = Platform.isWindows
          ? await _renderWindows(xml)
          : await _renderMobile(xml);
      if (!svg.contains('<svg')) {
        throw StateError('flutter_tex 没有返回公式 SVG');
      }
      svg = prepareFormulaSvg(svg);
      await file.writeAsString(svg, flush: true);
    }
    final element = XmlDocument.parse(svg).rootElement;
    final view = element
        .getAttribute('viewBox')!
        .split(RegExp(r'[\s,]+'))
        .map(double.parse)
        .toList();
    if (view.length != 4 || view[2] <= 0 || view[3] <= 0) {
      throw StateError('公式 SVG 尺寸为空');
    }
    // MathJax 的 SVG viewBox 使用每 em 1000 单位；y=0 就是数学基线。
    return RenderedFormula(
      resource: '${MathTypesetting.resourcePrefix}$key.svg',
      width: view[2] / 1000,
      height: view[3] / 1000,
      baseline: -view[1] / 1000,
    );
  }

  Future<String> _renderMobile(String xml) async {
    // 初始化失败的结果也共用，避免一章内每个公式都重复等待启动超时。
    await (_starting ??= TeXRenderingServer.start().timeout(
      const Duration(seconds: 30),
    ));
    return TeXRenderingServer.math2SVG(
      math: xml,
      mathInputType: MathInputType.mathML,
    ).future.timeout(const Duration(seconds: 15));
  }

  Future<String> _renderWindows(String xml) async {
    final controller = await (_windows ??= _startWindows());
    // 书内只提供 MathML 参数。页面和执行脚本都来自应用包。
    final value = await controller
        .evaluateJavascript(
          source:
              'MathJax.flutterTeXLiteDOM.math2SVG(${jsonEncode(xml)}, "mathML")',
        )
        .timeout(const Duration(seconds: 15));
    if (value is String) return value;
    throw StateError('Windows 公式转换未返回 SVG');
  }

  Future<InAppWebViewController> _startWindows() async {
    // 安装目录可能只读。使用当前应用的本地数据目录保存 WebView2 配置。
    final storage =
        windowsAppStorageRoot ?? (await getApplicationCacheDirectory()).path;
    final environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: '$storage/formula-webview',
      ),
    ).timeout(const Duration(seconds: 15));
    final loaded = Completer<InAppWebViewController>();
    final view = HeadlessInAppWebView(
      webViewEnvironment: environment,
      initialSize: const Size(32, 32),
      initialFile: 'packages/flutter_tex/core/flutter_tex.html',
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
      onLoadStop: (controller, _) {
        if (!loaded.isCompleted) loaded.complete(controller);
      },
      onReceivedError: (_, request, error) {
        if (!loaded.isCompleted && request.isForMainFrame != false) {
          loaded.completeError(StateError('无法加载本地公式页面：${error.description}'));
        }
      },
    );
    final running = view.run();
    Future<InAppWebViewController> start() async {
      await running;
      final controller = await loaded.future;
      final ready = await controller.callAsyncJavaScript(
        functionBody: '''
        await MathJax.startup.promise;
        return typeof MathJax.flutterTeXLiteDOM?.math2SVG === 'function';
      ''',
      );
      if (ready?.value != true) {
        throw StateError('本地 MathJax 初始化失败：${ready?.error ?? ''}');
      }
      return controller;
    }

    // 加载错误可能先于原生 run 返回，提前监听以免错误成为未处理异常。
    loaded.future.ignore();
    try {
      return await start().timeout(const Duration(seconds: 30));
    } catch (_) {
      // run 可能还在创建原生窗口，等它返回后再释放。
      running.whenComplete(() async {
        await view.dispose();
        await environment.dispose();
      }).ignore();
      rethrow;
    }
  }
}
