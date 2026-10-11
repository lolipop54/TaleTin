import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/bookshelf_view_model.dart';
import 'shelf_action_button.dart';
import 'shelf_more_menu.dart';

/// 标题与搜索保持同一个生命周期，进入多选只替换标题行。
class ShelfHeader extends ConsumerStatefulWidget {
  const ShelfHeader({super.key, required this.height, this.selectionHeader});

  final double height;
  final Widget? selectionHeader;

  @override
  ConsumerState<ShelfHeader> createState() => _ShelfHeaderState();
}

class _ShelfHeaderState extends ConsumerState<ShelfHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  late final TextEditingController _text;
  final _focus = FocusNode();
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    final query = ref.read(bookshelfProvider).query;
    _text = TextEditingController(text: query);
    _expanded = query.isNotEmpty;
    _animation = AnimationController(vsync: this, value: _expanded ? 1 : 0)
      ..addStatusListener(_onStatusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = context.gtMotion;
    _animation.duration = motion.fast + motion.normal;
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = _expanded ? 1 : 0;
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    // 收起完成后再清空，避免输入内容和筛选结果在动画中途跳变。
    // 快速反向展开时不会走到 dismissed，因此会保留尚在使用的关键词。
    if (status == AnimationStatus.dismissed && !_expanded) {
      // 系统关闭动画也可能在依赖更新中结束动画；等这一帧结束再发布筛选。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _expanded || !_animation.isDismissed) return;
        _text.clear();
        ref.read(bookshelfProvider.notifier).setQuery('');
      });
    }
  }

  void _toggleSearch() {
    setState(() => _expanded = !_expanded);
    if (!_expanded) _focus.unfocus();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = _expanded ? 1 : 0;
    } else if (_expanded) {
      _animation.forward();
    } else {
      _animation.reverse();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final motion = context.gtMotion;
    final split =
        motion.fast.inMicroseconds /
        (motion.fast + motion.normal).inMicroseconds;
    final space = _animation.drive(
      CurveTween(curve: Interval(0, split, curve: motion.curveEnter)),
    );
    final reveal = _animation.drive(
      CurveTween(curve: Interval(split, 1, curve: motion.curveEnter)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('shelf-header'),
          height: widget.height,
          child:
              widget.selectionHeader ??
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  GtSize.shelfPagePadding,
                  GtSpacing.s4,
                  GtSpacing.s4,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'TaleTin',
                          style: GtText.pageTitle(
                            colors.textPrimary,
                          ).copyWith(fontSize: 24, fontFamily: GtFonts.serif),
                        ),
                      ),
                    ),
                    ShelfActionButton(
                      key: const ValueKey('shelf-search-toggle'),
                      tooltip: _expanded ? '收起搜索' : '搜索',
                      icon: GtIcons.search,
                      selected: _expanded,
                      onPressed: _toggleSearch,
                    ),
                    const SizedBox(width: GtSpacing.s2),
                    ShelfActionButton(
                      key: const ValueKey('shelf-import'),
                      tooltip: '导入书籍',
                      icon: GtIcons.folderPlus,
                      onPressed: () => context.push(AppRoutes.import),
                    ),
                    const SizedBox(width: GtSpacing.s2),
                    const ShelfMoreMenu(),
                  ],
                ),
              ),
        ),
        AnimatedBuilder(
          animation: _animation,
          child: _buildSearch(colors),
          builder: (context, child) => Offstage(
            offstage: _animation.isDismissed,
            child: IgnorePointer(
              ignoring: !_expanded || !_animation.isCompleted,
              child: SizeTransition(
                key: const ValueKey('shelf-search-space'),
                sizeFactor: space,
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    GtSize.shelfPagePadding,
                    GtSpacing.s3,
                    GtSize.shelfPagePadding,
                    0,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.centerLeft,
                      child: ClipRect(
                        key: const ValueKey('shelf-search-reveal'),
                        // 始终按最终宽度排输入框，只揭开可见区域，文字不缩放。
                        child: Align(
                          alignment: Alignment.centerLeft,
                          widthFactor: reveal.value,
                          child: SizedBox(
                            width: constraints.maxWidth,
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearch(GtColors colors) => TextField(
    key: const ValueKey('shelf-search-field'),
    controller: _text,
    focusNode: _focus,
    onChanged: (value) => ref.read(bookshelfProvider.notifier).setQuery(value),
    textInputAction: TextInputAction.search,
    onSubmitted: (_) => _focus.unfocus(),
    style: GtText.body(colors.textPrimary),
    textAlignVertical: TextAlignVertical.center,
    decoration: InputDecoration(
      hintText: '搜索本地书籍',
      hintStyle: GtText.body(colors.textMuted),
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: GtSpacing.s3, right: GtSpacing.s2),
        child: GtIcon(
          GtIcons.search,
          size: GtSize.iconSmall,
          color: colors.textMuted,
        ),
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      filled: true,
      fillColor: colors.subtle,
      isDense: true,
      contentPadding: const EdgeInsets.all(GtSpacing.s3),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GtRadius.control),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
