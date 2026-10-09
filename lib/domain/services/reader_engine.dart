/// 阅读引擎契约（设计文档 4.3）：只做排版与位置换算，不保存任何业务数据。
///
/// 换实现（例如以后走 WebView）时只有这个契约的实现类需要替换，阅读页、
/// 书签、进度都不受影响。返回的 `ChapterLayout` 是引擎内部产物（里面带着测量
/// 得到的样式），放在 engine 层，契约文件只做类型引用。
library;

import 'dart:ui' show Offset, Rect;

import '../../engine/layout/chapter_layout.dart';
import '../../engine/layout/layout_options.dart';
import '../../engine/selection/selection_rects.dart';
import '../models/book_document.dart';
import '../models/locator.dart';

/// 一次排版请求的全部输入。
///
/// [options] 里的 `TextScaler` 必须是界面当前使用的**同一个**实例：Android 14+ 的
/// 系统字号缩放是非线性的，折算成单一系数会让测量与渲染行数不一致（设计文档 6.4）。
class LayoutRequest {
  const LayoutRequest({
    required this.bookId,
    required this.contentVersion,
    required this.chapter,
    required this.content,
    required this.options,
  });

  final String bookId;
  final int contentVersion;
  final Chapter chapter;
  final ChapterContent content;

  /// 排版参数（设置 + 内容区尺寸 + TextScaler）
  final LayoutOptions options;
}

abstract class ReaderEngine {
  /// 删除或替换正文后清除该书的旧排版。
  void invalidateLayout({String? bookId});

  /// 排一章：返回整章的页与位置换算。
  ///
  /// [token] 作废（参数已变或已切章）时抛 `LayoutCancelled`，调用方直接丢弃结果。
  Future<ChapterLayout> layoutChapter(
    LayoutRequest request, {
    LayoutToken? token,
  });

  /// 一页的首尾锚点。
  ({Locator start, Locator end}) pageBounds(ChapterLayout layout, int pageIndex);

  /// 内容位置 → 章内页序；不在本章时返回 null。
  PageRef? pageOf(ChapterLayout layout, Locator locator);

  /// 选区 → 页内高亮矩形（页内容盒坐标）。
  ///
  /// 跨章选区按章节顺序裁到本章：首章取到章末、末章从章首起、中间章整章。
  /// [chapterOrdinals] 是章节 ID → 阅读序号，缺省时只处理本章内的选区。
  List<Rect> selectionRects(
    ChapterLayout layout,
    int pageIndex,
    Locator from,
    Locator to, {
    Map<String, int>? chapterOrdinals,
  });

  /// 内容盒里的一点 → 文本位置（拖动定位用）；点在图片或空白上返回 null。
  Locator? locatorAtPoint(ChapterLayout layout, int pageIndex, Offset position);

  /// 选区端点的手柄位置（页内容盒坐标）；该端不在这页时返回 null。
  ///
  /// [atEnd] 为 true 表示这是选区的结束端（换行处贴在上一行末尾）。
  CaretGeometry? caretAt(
    ChapterLayout layout,
    int pageIndex,
    Locator locator, {
    required bool atEnd,
  });

  /// 一页的首/末文本位置（拖出手柄到页沿时先把选区铺到这一页）。
  Locator? pageEdge(ChapterLayout layout, int pageIndex, {required bool atEnd});

  /// 内容盒里的一点 → 它所在的整句（长按起选用）。
  ///
  /// 按句起选比按行起选更接近用户想选的东西；之后靠手柄逐字调整。
  ({Locator start, Locator end})? sentenceRangeAtPoint(
    ChapterLayout layout,
    int pageIndex,
    Offset position,
  );
}
