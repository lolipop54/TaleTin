import 'package:curved_navigation_bar/curved_navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/core/theme/gt_tokens.dart';
import '../../ui/core/widgets/gt_button.dart';

/// 只调整显示顺序，保留路由分支编号和各页已有状态。
class MainNavigationBar extends ConsumerWidget {
  const MainNavigationBar({
    super.key,
    required this.branchIndex,
    required this.onSelect,
  });
  final int branchIndex;
  final ValueChanged<int> onSelect;
  static const branches = [1, 0, 2]; // 成就、书架、设置；启动书架居中。
  static const labels = ['成就', '书架', '设置'];
  static const icons = [
    'assets/icons_used/成就tab.webp',
    'assets/icons_used/书架tab.webp',
    'assets/icons_used/设置tab.webp',
  ];

  /// 与实际渲染用相同的解码尺寸；三个图标在首页出现前一起准备好。
  static ImageProvider<Object> iconImage(String asset, BuildContext context) =>
      ResizeImage.resizeIfNeeded(
        (32 * MediaQuery.devicePixelRatioOf(context)).ceil(),
        null,
        AssetImage(asset),
      );
  static Future<void> prepareIcons(BuildContext context) async {
    await Future.wait([
      for (final asset in icons)
        precacheImage(iconImage(asset, context), context),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    // 浅色TabBar和系统底部安全区使用纯白，夜间仍沿用深色面板底色。
    final barColor = Theme.of(context).brightness == Brightness.dark
        ? colors.surface
        : GtPalette.navigationBackground;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 系统三键栏与TabBar共用底色；边到边模式只在下方安全区铺底。
      // 关闭系统额外的对比度蒙层，避免原底面被另加一层灰或白。
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: barColor,
        systemNavigationBarDividerColor: barColor,
        systemNavigationBarContrastEnforced: false,
        systemNavigationBarIconBrightness:
            Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CurvedNavigationBar(
            index: branches.indexOf(branchIndex),
            height: GtSize.bottomNavHeight,
            color: barColor,
            buttonBackgroundColor: barColor,
            // 轻阴影直接沿曲线与圆钮绘制，凹口其余区域保持透明。
            elevation: 2,
            shadowColor: Theme.of(context).shadowColor.withValues(alpha: 0.18),
            backgroundColor: Colors.transparent,
            animationDuration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 320),
            animationCurve: Curves.easeOutCubic,
            // 由路由在目标数据就绪后更新 index。这里也接收动画中的新点击，
            // 不让组件自己抢先换选中项或忽略用户的最后一次操作。
            letIndexChange: (index) {
              onSelect(branches[index]);
              return false;
            },
            items: [
              for (var index = 0; index < branches.length; index++)
                GtButton.raw(
                  key: ValueKey('main-nav-${branches[index]}'),
                  tooltip: labels[index],
                  selected: branches[index] == branchIndex,
                  onPressed: () => onSelect(branches[index]),
                  child: SizedBox.square(
                    dimension: 32,
                    child: Center(
                      child: Image(
                        image: iconImage(icons[index], context),
                        width: 32,
                        height: 32,
                        fit: BoxFit.contain,
                        colorBlendMode: BlendMode.srcIn,
                        color: branches[index] == branchIndex
                            ? colors.actionPrimary
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          ColoredBox(
            color: barColor,
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
          ),
        ],
      ),
    );
  }
}
