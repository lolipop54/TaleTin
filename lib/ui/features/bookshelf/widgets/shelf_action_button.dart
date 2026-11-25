import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';

/// 分组和详情面板共用胶囊样式，浅色和深色各用主题的淡底色。
ButtonStyle shelfSheetActionStyle(GtColors colors) => ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(52, 30)),
  tapTargetSize: MaterialTapTargetSize.padded,
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  ),
  shape: const WidgetStatePropertyAll(StadiumBorder()),
  backgroundColor: WidgetStatePropertyAll(colors.subtle),
  textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13)),
);
