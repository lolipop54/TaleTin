import 'dart:async';

import 'math_formula.dart';

/// 平台转换环境由应用启动时安装；测量与单元测试不直接依赖 WebView 插件。
abstract interface class FormulaRenderer {
  Future<RenderedFormula> render(String xml);
}

abstract final class MathTypesetting {
  static FormulaRenderer? renderer;
  static String? cacheRoot;
  static const resourcePrefix = 'gt-math/';
  static const revision = 'flutter-tex-5.3.0-v1';
  static String? resourceFile(String resource) =>
      resource.startsWith(resourcePrefix) && cacheRoot != null
      ? '$cacheRoot/${resource.substring(resourcePrefix.length)}'
      : null;
}
