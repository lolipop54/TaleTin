import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// assets/icons 下的 SVG 图标名（24×24 线性风格，stroke 1.75）。
/// 通过 [GtIcon] 渲染并用主题色覆盖 currentColor。
abstract final class GtIcons {
  static const arrowBack = 'arrow-back';
  static const chevronDown = 'chevron-down';
  static const chevronLeft = 'chevron-left';
  static const chevronRight = 'chevron-right';
  static const chevronUp = 'chevron-up';
  static const close = 'close';
  static const check = 'check';
  static const checkCircle = 'check-circle';
  static const plus = 'plus';
  static const minus = 'minus';
  static const search = 'search';
  static const sort = 'sort';
  static const grid = 'grid';
  static const list = 'list';
  static const dragHandle = 'drag-handle';
  static const moreVertical = 'more-vertical';
  // 主导航与书架
  static const books = 'books';
  static const trophy = 'trophy';
  static const settings = 'settings';
  static const folderPlus = 'folder-plus';
  static const folder = 'folder';
  static const folderInput = 'folder-input';
  static const filter = 'filter';
  static const checkbox = 'checkbox';
  static const checkboxSelected = 'checkbox-selected';
  static const folderUp = 'folder-up';
  static const caretDown = 'caret-down';
  static const bookmark = 'bookmark';
  static const toc = 'toc';
  // 阅读控制
  static const brightness = 'brightness';
  static const font = 'font';
  static const headphones = 'headphones';
  static const autoRead = 'auto-read';
  static const locator = 'locator';
  static const sunLow = 'sun-low';
  static const sunHigh = 'sun-high';
  static const reset = 'reset';
  static const battery = 'battery';
  static const screenOn = 'screen-on';
  // 播放与听书
  static const play = 'play';
  static const pause = 'pause';
  static const skipPrevious = 'skip-previous';
  static const skipNext = 'skip-next';
  static const stepPrevious = 'step-previous';
  static const stepNext = 'step-next';
  static const voice = 'voice';
  static const gauge = 'gauge';
  static const clock = 'clock';
  static const waveform = 'waveform';
  // 设置与数据
  static const palette = 'palette';
  static const sparkles = 'sparkles';
  static const eye = 'eye';
  static const page = 'page';
  static const database = 'database';
  static const broom = 'broom';
  static const export = 'export';
  static const restore = 'restore';
  static const file = 'file';
  static const documentText = 'document-text';
  static const info = 'info';
  // 导入与状态
  static const alertCircle = 'alert-circle';
  static const lock = 'lock';
  static const retry = 'retry';
  // 笔记与成就
  static const note = 'note';
  static const notePlus = 'note-plus';
  static const highlight = 'highlight';
  static const trash = 'trash';
  static const calendar = 'calendar';
  static const openBook = 'open-book';
  static const leaf = 'leaf';
  static const lantern = 'lantern';
  static const moonStars = 'moon-stars';
  static const award = 'award';
}

/// 项目 SVG 图标：对应 `assets/icons/<name>.svg`。
/// 颜色通过 colorFilter 覆盖 SVG 的 currentColor。
class GtIcon extends StatelessWidget {
  const GtIcon(this.name, {super.key, this.size = 24, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}
