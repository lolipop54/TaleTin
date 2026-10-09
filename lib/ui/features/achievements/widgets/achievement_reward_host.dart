import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/achievement_providers.dart';
import '../../../../app/router/main_pages_ready.dart';
import '../../../../domain/rules/achievement_rules.dart';
import 'achievement_celebration.dart';

/// 奖励仅在成就页当前可见时展示，不打断正文、其他 Tab 或后台。
class AchievementRewardHost extends ConsumerStatefulWidget {
  const AchievementRewardHost({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<AchievementRewardHost> createState() =>
      _AchievementRewardHostState();
}

class _AchievementRewardHostState extends ConsumerState<AchievementRewardHost> {
  bool busy = false, scheduled = false;
  bool entered = false;
  late final lifecycle = AppLifecycleListener(onResume: schedule);
  @override
  void initState() {
    super.initState();
    lifecycle;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    schedule();
  }

  bool get visible =>
      mounted &&
      MainPagesReady.isCurrentOf(context) &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.isCurrentOf(context) ?? true) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  void schedule() {
    if (scheduled || !mounted) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (mounted) drain();
    });
  }

  Future<void> drain() async {
    if (busy ||
        !visible ||
        ref
                .read(achievementPageProvider)
                .value
                ?.unlocks
                .any((u) => !u.presented) !=
            true) {
      return;
    }
    busy = true;
    try {
      final service = ref.read(achievementServiceProvider);
      while (visible) {
        final pending =
            service.snapshot?.unlocks
                .where(
                  (u) =>
                      !u.presented && achievementRules.any((r) => r.id == u.id),
                )
                .toList() ??
            [];
        if (pending.isEmpty) break;
        final id = pending.first.id;
        if (!await service.claim(id) || !mounted || !visible) {
          break;
        }
        final reduced = MediaQuery.disableAnimationsOf(context);
        await showDialog<void>(
          context: context,
          builder: (_) => AchievementCelebration(
            rule: achievementRules.firstWhere((r) => r.id == id),
            reduced: reduced,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('奖励展示状态未保存，请稍后重试')));
      }
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(achievementPageProvider, (_, _) => schedule());
    // 隐藏分支提前构建内容，但首次渐入从真正切到成就页时开始。
    entered = entered || TickerMode.valuesOf(context).enabled;
    if (!entered) return Opacity(opacity: 0, child: widget.child);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: reduced ? 150 : 220),
      builder: (_, value, child) => Opacity(opacity: value, child: child),
      child: widget.child,
    );
  }

  @override
  void dispose() {
    lifecycle.dispose();
    super.dispose();
  }
}
