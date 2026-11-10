import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_tex/flutter_tex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../../engine/layout/math_formula.dart';
import '../../engine/layout/math_typesetting.dart';
import 'formula_svg.dart';

/// 复用 flutter_tex 的公开 MathML → SVG 接口；阅读器只接收矢量和尺寸。
/// 转换发生在页面准备阶段，普通章节不会启动公式服务。
class FlutterTexFormulaRenderer implements FormulaRenderer {
  Future<void>? _starting;
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
      // 初始化失败的结果也共用，避免一章内每个公式都重复等待启动超时。
      await (_starting ??= TeXRenderingServer.start().timeout(
        const Duration(seconds: 30),
      ));
      svg = await TeXRenderingServer.math2SVG(
        math: xml,
        mathInputType: MathInputType.mathML,
      ).future.timeout(const Duration(seconds: 15));
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
}
