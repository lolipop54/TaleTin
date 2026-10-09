import 'package:flutter/material.dart';

/// 占位封面的图形主题。
enum CoverArt {
  moonSea, // 月夜海面
  brush, // 水墨留白
  forest, // 密林
  botanical, // 植物线描
  skyVillage, // 天空与小镇
  starField, // 星野
  inkTree, // 水墨树影
  shopWindow, // 夜色橱窗
  island, // 远岛海面
  foliage, // 叶片纹样
  geometric, // 几何抽象
  street, // 街景
}

/// 标题在封面里的排布方式。
enum CoverTitleLayout { center, lower, rightVertical }

/// 一本书的占位封面样式：底色、图形主色、文字颜色与排布。
class CoverSpec {
  const CoverSpec({
    required this.art,
    required this.background,
    required this.ink,
    required this.titleColor,
    required this.authorColor,
    this.backgroundEnd,
    this.titleLayout = CoverTitleLayout.center,
    this.subtitle,
    this.showCoverAuthor = true,
    this.titleAlign = Alignment.center,
  });

  final CoverArt art;
  final Color background;

  /// 渐变终止色；为空时使用纯色底。
  final Color? backgroundEnd;

  /// 图形主色。
  final Color ink;
  final Color titleColor;
  final Color authorColor;
  final CoverTitleLayout titleLayout;

  /// 封面上的小字外文或副题。
  final String? subtitle;

  /// 是否在封面内显示中文作者。
  final bool showCoverAuthor;

  /// 标题块在封面里的位置，橱窗类封面需要上移。
  final Alignment titleAlign;

  static const _fallback = CoverSpec(
    art: CoverArt.geometric,
    background: Color(0xFFE9EDF2),
    ink: Color(0xFF4A5A78),
    titleColor: Color(0xFF2A3242),
    authorColor: Color(0xFF5B6678),
  );

  static const Map<String, CoverSpec> _byBook = {
    'b01': CoverSpec(
      art: CoverArt.moonSea,
      background: Color(0xFF0D1B2E),
      backgroundEnd: Color(0xFF17324F),
      ink: Color(0xFFE9E4D3),
      titleColor: Color(0xFFF2EFE6),
      authorColor: Color(0xFFB9C3D2),
      subtitle: 'W. Somerset Maugham',
      showCoverAuthor: false,
    ),
    'b02': CoverSpec(
      art: CoverArt.brush,
      background: Color(0xFFF3F0E9),
      ink: Color(0xFF23231F),
      titleColor: Color(0xFF1E1E1A),
      authorColor: Color(0xFF4C4C46),
      titleLayout: CoverTitleLayout.rightVertical,
    ),
    'b03': CoverSpec(
      art: CoverArt.forest,
      background: Color(0xFF16241C),
      backgroundEnd: Color(0xFF24402C),
      ink: Color(0xFF0E1A12),
      titleColor: Color(0xFFF0F3EE),
      authorColor: Color(0xFFC3CFC4),
      titleLayout: CoverTitleLayout.rightVertical,
      subtitle: 'ノルウェイの森',
    ),
    'b04': CoverSpec(
      art: CoverArt.botanical,
      background: Color(0xFFF4F1E9),
      ink: Color(0xFF4A4A40),
      titleColor: Color(0xFF24241E),
      authorColor: Color(0xFF5C5C52),
      subtitle: 'Sapiens',
    ),
    'b05': CoverSpec(
      art: CoverArt.skyVillage,
      background: Color(0xFF6FA9D8),
      backgroundEnd: Color(0xFFCBE2F2),
      ink: Color(0xFFF7FBFF),
      titleColor: Color(0xFFFDFEFF),
      authorColor: Color(0xFFE8F2FA),
      titleLayout: CoverTitleLayout.lower,
    ),
    'b06': CoverSpec(
      art: CoverArt.starField,
      background: Color(0xFF0A0D14),
      backgroundEnd: Color(0xFF141E30),
      ink: Color(0xFFEAF0F8),
      titleColor: Color(0xFFF1F5FB),
      authorColor: Color(0xFFB4C0D2),
      subtitle: 'CIXIN LIU',
    ),
    'b07': CoverSpec(
      art: CoverArt.inkTree,
      background: Color(0xFFEFEAE0),
      ink: Color(0xFF2B2B27),
      titleColor: Color(0xFF23231F),
      authorColor: Color(0xFF55554E),
      titleLayout: CoverTitleLayout.center,
    ),
    'b08': CoverSpec(
      art: CoverArt.shopWindow,
      background: Color(0xFF101B2E),
      backgroundEnd: Color(0xFF1B2C45),
      ink: Color(0xFFE4B368),
      titleColor: Color(0xFFF2EEE4),
      authorColor: Color(0xFFBFC7D4),
      subtitle: 'ナミヤ雑貨店の奇蹟',
      titleAlign: Alignment(0, -0.42),
    ),
    'b09': CoverSpec(
      art: CoverArt.island,
      background: Color(0xFFEDE8DC),
      ink: Color(0xFF9AA3A8),
      titleColor: Color(0xFF2B2B26),
      authorColor: Color(0xFF5A5A52),
      titleLayout: CoverTitleLayout.lower,
    ),
    'b10': CoverSpec(
      art: CoverArt.foliage,
      background: Color(0xFF16301F),
      backgroundEnd: Color(0xFF1F4229),
      ink: Color(0xFF2C5B3A),
      titleColor: Color(0xFFF1F4EC),
      authorColor: Color(0xFFC6D2C0),
      titleLayout: CoverTitleLayout.lower,
      subtitle: 'Cien años\nde soledad',
    ),
    'b11': CoverSpec(
      art: CoverArt.geometric,
      background: Color(0xFFF6F6F3),
      ink: Color(0xFF33507F),
      titleColor: Color(0xFF1F2A3C),
      authorColor: Color(0xFF5A6474),
      titleLayout: CoverTitleLayout.lower,
      subtitle: "L'Étranger",
    ),
    'b12': CoverSpec(
      art: CoverArt.street,
      background: Color(0xFFE9E7E2),
      ink: Color(0xFF7C7C78),
      titleColor: Color(0xFF26262A),
      authorColor: Color(0xFF4E4E52),
      titleLayout: CoverTitleLayout.rightVertical,
    ),
  };

  static CoverSpec of(String bookId) => _byBook[bookId] ?? _fallback;
}
