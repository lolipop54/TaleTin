import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/gt_tokens.dart';
import 'taletin_loading_art.dart';

/// 原应用图标保持静止，柔和亮带从左向右扫描。
class BookLoading extends StatefulWidget {
  const BookLoading({super.key, this.color, this.label});
  final Color? color;
  final String? label;

  /// 首页释放首帧前准备好共用图案，首次开书无需再等图片解码。
  static Future<void> prepare() => TaleTinLoadingArt.prepare();

  @override
  State<BookLoading> createState() => _BookLoadingState();
}

class _BookLoadingState extends State<BookLoading>
    with SingleTickerProviderStateMixin {
  late final _scan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (TaleTinLoadingArt.image == null) _prepare();
  }

  Future<void> _prepare() async {
    await BookLoading.prepare();
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _scan.stop();
      _scan.value = 0;
    } else if (!_scan.isAnimating) {
      _scan.repeat();
    }
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = TaleTinLoadingArt.image != null;
    final art = RepaintBoundary(
      child: SizedBox.square(
        dimension: 120,
        child: ready
            ? CustomPaint(
                painter: TaleTinLoadingPainter(
                  _scan,
                  widget.color ??
                      (Theme.of(context).brightness == Brightness.dark
                          ? context.gtColors.textPrimary
                          : Colors.black),
                ),
              )
            : null,
      ),
    );
    if (widget.label == null) return art;
    // 动画只重绘图案，文字和周围布局保持不变。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        art,
        const SizedBox(height: GtSpacing.s3),
        Opacity(
          opacity: ready ? 1 : 0,
          child: Text(
            widget.label!,
            textAlign: TextAlign.center,
            style: GtText.body(context.gtColors.textSecondary)
                .copyWith(fontSize: 14),
          ),
        ),
      ],
    );
  }
}

@Preview(name: 'TaleTin 扫描加载', size: Size(280, 240))
Widget bookLoadingPreview() => FutureBuilder<void>(
  // Previewer 把本项目作为依赖加载，因此素材使用包内路径。
  future: TaleTinLoadingArt.prepare(assetPrefix: 'packages/taletin/'),
  builder: (context, snapshot) => MaterialApp(
    home: Scaffold(
      body: snapshot.connectionState == ConnectionState.done
          ? const Center(child: BookLoading())
          : const SizedBox.shrink(),
    ),
  ),
);
