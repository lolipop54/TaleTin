import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/gt_tokens.dart';
import 'gt_icon.dart';
import 'gt_round_action_button.dart';

/// 标题按钮和列表上方的搜索框共用动画；两个入口分别保存自己的筛选条件。
mixin GtExpandableSearch<T extends StatefulWidget> on State<T>, TickerProvider {
  String get searchKey;
  String get searchHint;
  String get initialSearchText => '';
  void onSearchChanged(String value);
  late final AnimationController _animation;
  late final TextEditingController _text;
  final _focus = FocusNode();
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    final query = initialSearchText;
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
        clearSearchText();
      });
    }
  }

  void clearSearchText() {
    _text.clear();
    onSearchChanged('');
  }

  Widget buildSearchButton({bool showTooltipOnWindows = true}) =>
      GtRoundActionButton(
        key: ValueKey('$searchKey-toggle'),
        tooltip: _expanded ? '收起搜索' : '搜索',
        showTooltipOnWindows: showTooltipOnWindows,
        icon: GtIcons.search,
        selected: _expanded,
        onPressed: _toggleSearch,
      );

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

  Widget buildSearchField(BuildContext context, {double bottomSpacing = 0}) {
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
    return AnimatedBuilder(
      animation: _animation,
      child: _buildSearch(colors),
      builder: (context, child) => Offstage(
        offstage: _animation.isDismissed,
        child: IgnorePointer(
          ignoring: !_expanded || !_animation.isCompleted,
          child: SizeTransition(
            key: ValueKey('$searchKey-space'),
            sizeFactor: space,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                GtSize.shelfPagePadding,
                GtSpacing.s3,
                GtSize.shelfPagePadding,
                bottomSpacing,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Align(
                  alignment: Alignment.centerLeft,
                  child: ClipRect(
                    key: ValueKey('$searchKey-reveal'),
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
    );
  }

  Widget _buildSearch(GtColors colors) => TextField(
    key: ValueKey('$searchKey-field'),
    controller: _text,
    focusNode: _focus,
    onChanged: onSearchChanged,
    textInputAction: TextInputAction.search,
    onSubmitted: (_) => _focus.unfocus(),
    style: GtText.body(colors.textPrimary),
    textAlignVertical: TextAlignVertical.center,
    decoration: InputDecoration(
      hintText: searchHint,
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
