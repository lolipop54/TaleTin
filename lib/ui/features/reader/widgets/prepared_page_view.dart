import 'package:flutter/material.dart';

import 'page_canvas.dart';
import 'prepared_page.dart';

class PreparedPageTransfer extends InheritedWidget {
  const PreparedPageTransfer({
    super.key,
    required this.page,
    required super.child,
  });
  final PreparedPage? page;
  @override
  bool updateShouldNotify(PreparedPageTransfer old) => old.page != page;
}

/// 同一阅读槽保留旧页，目标页图片就绪后整体替换。
class PreparedPageView extends StatefulWidget {
  const PreparedPageView({super.key, required this.page});
  final PageCanvas page;

  @override
  State<PreparedPageView> createState() => _PreparedPageViewState();
}

class _PreparedPageViewState extends State<PreparedPageView> {
  PreparedPage? _ready;
  PageCanvas? _requested;
  ImageConfiguration? _configuration;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prepare();
  }

  @override
  void didUpdateWidget(PreparedPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _prepare();
  }

  bool _sameContent(PageCanvas? a, PageCanvas b) =>
      a != null && a.layout.samePageAs(b.layout, a.pageIndex, b.pageIndex);

  void _prepare() {
    final page = widget.page;
    final transfer = context
        .dependOnInheritedWidgetOfExactType<PreparedPageTransfer>()
        ?.page;
    final configuration = createLocalImageConfiguration(context);
    // 相邻页可能已经开始异步加载；动画材料稍后就绪时仍要立即接收，
    // 不能因“请求过同一页”跳过交接，继续显示旧页或空白。
    final canReceive =
        _sameContent(transfer?.page, page) && !_sameContent(_ready?.page, page);
    if (_sameContent(_requested, page) &&
        configuration == _configuration &&
        !canReceive) {
      if (_sameContent(_ready?.page, page)) page.onReady?.call();
      return;
    }
    _requested = page;
    _configuration = configuration;
    final request = ++_request;
    // 切书不能暂留上一本文字；同书换页和重新排版则保留旧页。
    if (_ready?.page.layout.bookId != page.layout.bookId) {
      _ready?.dispose();
      _ready = null;
    }
    // 动画中的失败占位不能作为静态页的有效图片继续复用；
    // 提交位置已补齐资源时重新解码，准备期间继续保留旧页。
    final text =
        _sameContent(transfer?.page, page) && !transfer!.hasFailedImages
        ? transfer.clone()
        : PreparedPage.textOnly(page);
    if (text != null) {
      _ready?.dispose();
      _ready = text;
      page.onReady?.call();
      return;
    }
    PreparedPage.load(page, configuration).then((loaded) {
      if (!mounted || request != _request) {
        loaded.dispose();
        return;
      }
      setState(() {
        _ready?.dispose();
        _ready = loaded;
        widget.page.onReady?.call();
      });
    });
  }

  @override
  void dispose() {
    _ready?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    if (ready == null) return const Center(child: SizedBox.shrink());
    final appearance = _sameContent(ready.page, widget.page)
        ? widget.page
        : ready.page;
    return CustomPaint(
      painter: _PreparedPainter(ready, appearance),
      size: Size.infinite,
    );
  }
}

class _PreparedPainter extends CustomPainter {
  const _PreparedPainter(this.page, this.appearance);
  final PreparedPage page;
  final PageCanvas appearance;

  @override
  void paint(Canvas canvas, Size size) =>
      page.paint(canvas, size, appearance: appearance);

  @override
  bool shouldRepaint(_PreparedPainter old) =>
      old.page != page || old.appearance != appearance;
}
