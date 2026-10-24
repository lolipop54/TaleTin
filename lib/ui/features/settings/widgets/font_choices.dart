import 'package:flutter/material.dart';

import '../../../../domain/models/reading_settings.dart';
import '../../../../platform/channels/reading_fonts.dart';
import '../../../../platform/channels/preset_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';

/// 全局字体页和单书弹层使用相同候选、别名和真实字体预览。
String selectedFontChoice(
  ReadingSettings settings, {
  bool supportsOriginalFont = true,
}) =>
    supportsOriginalFont &&
        settings.layoutMode.isOriginal &&
        settings.useOriginalFont
    ? '__original'
    // 旧版打开字体面板时可能已保存当前系统字体的具体编号。
    : settings.fontFamily == null ||
          settings.fontFamily == 'sans-serif' ||
          ReadingFonts.resolve(settings.fontFamily) ==
              ReadingFonts.resolve('sans-serif')
    ? 'sans-serif'
    : ReadingFonts.resolve(settings.fontFamily)!;

Map<String, String> readingFontChoices(
  ReadingSettings settings,
  Map<String, String?> fonts, {
  bool supportsOriginalFont = true,
  List<String> order = const [],
}) {
  final defaults = <String, String>{
    if (supportsOriginalFont && settings.layoutMode.isOriginal)
      '__original': '原书字体',
    'sans-serif': '系统字体',
    // 内置字体紧跟系统字体，顺序取自内置目录，不受设备返回名单顺序影响。
    for (final id in PresetFonts.families.keys)
      if (fonts.containsKey(id)) id: fonts[id] ?? id,
    for (final entry in fonts.entries)
      if (entry.key != 'sans-serif' && !entry.key.startsWith('gt-preset-'))
        entry.key: entry.value ?? entry.key,
  };
  return {
    if (defaults.containsKey('__original'))
      '__original': defaults['__original']!,
    'sans-serif': defaults['sans-serif']!,
    for (final id in order.toSet())
      if (id != '__original' && id != 'sans-serif' && defaults.containsKey(id))
        id: defaults[id]!,
    for (final entry in defaults.entries)
      if (entry.key != '__original' &&
          entry.key != 'sans-serif' &&
          !order.contains(entry.key))
        entry.key: entry.value,
  };
}

TextStyle fontChoiceStyle(BuildContext context, String id, bool active) =>
    GtText.body(
      active ? context.gtColors.actionPrimary : context.gtColors.textPrimary,
    ).copyWith(
      fontFamily: id == '__original'
          ? null
          : PresetFonts.previewFamily(ReadingFonts.resolve(id)!),
    );
