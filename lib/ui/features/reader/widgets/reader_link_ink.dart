import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../../domain/models/book_document.dart';
import '../../../../engine/layout/measured_block.dart';
import '../../../../engine/styles/chapter_styler.dart';
import '../../../../engine/styles/style_table.dart';

/// 当前阅读会话的链接颜色只改变绘制，不触发分页或改动文字位置。
class ReaderLinkInk extends ChangeNotifier {
  static final _books = <String, ReaderLinkInk>{};
  static final _hasColors = Expando<bool>();
  static ReaderLinkInk forBook(String id) =>
      _books.putIfAbsent(id, ReaderLinkInk.new);
  static int revisionOf(String id) => _books[id]?.revision ?? 0;
  static void closeBook(String id) => _books.remove(id);
  static LinkAppearance? appearance(String id, ChapterContent content) {
    final table = ChapterStyler.layoutTableOf(content);
    if (!(_hasColors[table] ??= table.records.any(
      (s) => s.text.activeInk != null || s.text.visitedInk != null,
    ))) {
      return null;
    }
    final state = forBook(id)..hasAuthorColors = true;
    return LinkAppearance(state, table);
  }

  bool hasAuthorColors = false;
  final visited = <String>{};
  String? pressed;
  int revision = 0;

  void press(String? href) {
    if (pressed == href) return;
    pressed = href;
    revision++;
    notifyListeners();
  }

  void visit(String href) {
    if (visited.add(href)) {
      revision++;
      notifyListeners();
    }
  }
}

class LinkAppearance {
  const LinkAppearance(this.state, this.table);
  final ReaderLinkInk state;
  final StyleTable table;

  MeasuredBlock resolve(MeasuredBlock block) {
    if (state.pressed == null && state.visited.isEmpty) return block;
    List<TextStyle>? colors;
    for (var i = 0; i < block.runs.length; i++) {
      final run = block.runs[i], href = run.link;
      if (href == null) continue;
      final style = table[run.styleId ?? 0].text;
      final visited = state.visited.contains(href) ? style.visitedInk : null;
      final color = href == state.pressed
          ? style.activeInk ?? visited
          : visited;
      if (color == null) continue;
      colors ??= List.of(block.runStyles);
      colors[i] = colors[i].copyWith(color: Color(color.argb));
    }
    return colors == null
        ? block
        : block.withBoxEdges(
            first: block.boxFirst,
            last: block.boxLast,
            paintStyles: colors,
          );
  }
}

/// 使用实际链接命中范围。开始拖动、松手、取消触摸都会撤下按压色。
class ReaderLinkPress extends StatefulWidget {
  const ReaderLinkPress({
    super.key,
    required this.bookId,
    required this.hit,
    required this.child,
  });
  final String bookId;
  final String? Function(Offset) hit;
  final Widget child;
  @override
  State<ReaderLinkPress> createState() => _ReaderLinkPressState();
}

class _ReaderLinkPressState extends State<ReaderLinkPress> {
  int? pointer;
  Offset origin = Offset.zero;
  ReaderLinkInk? state;
  void release() {
    state?.press(null);
    state = null;
    pointer = null;
  }

  @override
  void dispose() {
    release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (e) {
      if (pointer != null ||
          e.buttons != kPrimaryButton ||
          ReaderLinkInk._books[widget.bookId]?.hasAuthorColors != true) {
        return;
      }
      final href = widget.hit(e.localPosition);
      if (href == null) return;
      pointer = e.pointer;
      origin = e.localPosition;
      state = ReaderLinkInk.forBook(widget.bookId)..press(href);
    },
    onPointerMove: (e) {
      if (e.pointer == pointer &&
          (e.localPosition - origin).distance > kTouchSlop) {
        release();
      }
    },
    onPointerUp: (e) {
      if (e.pointer == pointer) release();
    },
    onPointerCancel: (e) {
      if (e.pointer == pointer) release();
    },
    child: widget.child,
  );
}
