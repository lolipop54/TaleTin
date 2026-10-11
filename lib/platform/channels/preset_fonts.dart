import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'preset_font_previews.dart';

/// 内置字体的名称和文件共用一份目录；字重在 pubspec 中明确注册。
/// 部分 Bold 文件内部仍标成 400，不能用 FontLoader 猜测其字重。
/// 增删步骤见 docs/内置字体维护说明.md；这里的条目顺序就是字体页的内置顺序。
abstract final class PresetFonts {
  /// Android 打包同时按此参数排除完整字体和名称预览，默认仍包含内置字体。
  static const included = bool.fromEnvironment(
    'GT_INCLUDE_PRESET_FONTS',
    defaultValue: true,
  );
  static const families = included
      ? catalog
      : <String, ({String name, String file, String? bold})>{};
  static const catalog = <String, ({String name, String file, String? bold})>{
    'gt-preset-cangeryumo': (
      name: '仓耳与墨',
      file: '仓耳与墨/仓耳与墨.ttf',
      bold: '仓耳与墨/仓耳与墨-Bold.ttf',
    ),
    'gt-preset-cangeryuyang': (
      name: '仓耳渔阳体',
      file: '仓耳渔阳体/仓耳渔阳体.ttf',
      bold: '仓耳渔阳体/仓耳渔阳体-Bold.ttf',
    ),
    'gt-preset-cangershuyuan': (
      name: '仓耳舒圆体',
      file: '仓耳舒圆体/仓耳舒圆体.ttf',
      bold: '仓耳舒圆体/仓耳舒圆体-Bold.ttf',
    ),
    'gt-preset-jingnanbobo': (name: '荆南波波黑', file: '荆南波波黑.ttf', bold: null),
    'gt-preset-screenserif': (name: '思源屏显臻宋', file: '思源屏显臻宋.ttf', bold: null),
    'gt-preset-lxgwwenkai': (
      name: '霞鹜文楷',
      file: '霞鹜文楷/霞鹜文楷.ttf',
      bold: '霞鹜文楷/霞鹜文楷-Bold.ttf',
    ),
    'gt-preset-lxgwmanhei': (name: '霞鹜漫黑', file: '霞鹜漫黑.ttf', bold: null),
    'gt-preset-lxgwzhenkai': (name: '霞鹜臻楷', file: '霞鹜臻楷.ttf', bold: null),
    'gt-preset-homepencil': (name: '宅在家自動筆', file: '宅在家自動筆.ttf', bold: null),
    'gt-preset-ideals': (name: '自由理想体', file: '自由理想体.ttf', bold: null),
  };
  static const root = 'assets/fonts/preset/';
  static final _prepared = <String>{};
  static final _preparedPreviews = <String>{};

  static Map<String, String> get names => {
    for (final entry in families.entries) entry.key: '${entry.value.name}（内置）',
  };

  /// 名称预览只用少量字形；新字体或改名后尚未生成时仍用完整字体显示。
  /// 预览编号只用于列表，不能写入全局或单书的字体设置。
  static String previewFamily(String family) {
    final font = families[family];
    return font != null && presetFontPreviewNames[family] == '${font.name}（内置）'
        ? family.replaceFirst('gt-preset-', 'gt-preview-')
        : family;
  }

  /// 开面板前准备小预览，首帧不再同步读取整套中文字体；重复打开直接复用。
  static void preparePreviews() {
    for (final family in families.keys) {
      final preview = previewFamily(family);
      if (preview == family || _preparedPreviews.contains(family)) continue;
      _prepareParagraphs(preview, presetFontPreviewNames[family]!);
      _preparedPreviews.add(family);
    }
  }

  /// 只预排当前选择的字体，系统字体启动不读取整套内置资源。
  /// 原生字体管理器按 pubspec 的 400/700 匹配，首次显示前完成字形准备。
  static void prepare(String family) {
    if (_prepared.contains(family)) return;
    _prepareParagraphs(family, '阅读 Aa');
    _prepared.add(family);
  }

  static void _prepareParagraphs(String family, String text) {
    for (final weight in [ui.FontWeight.normal, ui.FontWeight.bold]) {
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(fontFamily: family, fontWeight: weight, fontSize: 16),
      )..addText(text);
      final paragraph = builder.build()
        ..layout(const ui.ParagraphConstraints(width: 200));
      paragraph.dispose();
    }
  }

  static String cssFor(String family) {
    final font = families[family]!;
    String face(String resource, int weight) =>
        '@font-face{font-family:"$family";'
        'src:url("/__gt_fonts/$resource");font-weight:$weight;font-style:normal;}';
    return face(family, 400) +
        (font.bold == null ? '' : face('$family-bold', 700));
  }

  static Future<Uint8List?> bytes(String resource) async {
    final bold = resource.endsWith('-bold');
    final family = bold ? resource.substring(0, resource.length - 5) : resource;
    final font = families[family];
    final file = bold ? font?.bold : font?.file;
    if (file == null) return null;
    final data = await rootBundle.load('$root$file');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
