import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/rules/achievement_rules.dart';
import '../../../core/theme/gt_tokens.dart';
import 'achievement_wall.dart';

class AchievementCelebration extends StatefulWidget {
  const AchievementCelebration({
    super.key,
    required this.rule,
    required this.reduced,
  });
  final AchievementRule rule;
  final bool reduced;
  @override
  State<AchievementCelebration> createState() => _AchievementCelebrationState();
}

class _AchievementCelebrationState extends State<AchievementCelebration>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.reduced ? 150 : 1200),
  )..forward();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: GtButton.icon(
              tooltip: '关闭奖励',
              onPressed: () => Navigator.pop(context),
              icon: Icon(Icons.close, color: context.gtColors.textPrimary),
            ),
          ),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final t = controller.value;
              final scale = widget.reduced
                  ? 1.0
                  : t < .65
                  ? .85 + .2 * Curves.easeOut.transform(t / .65)
                  : 1.05 - .05 * ((t - .65) / .35);
              return Opacity(
                opacity: (t * (widget.reduced ? 1 : 4)).clamp(0.0, 1.0),
                child: Column(
                  children: [
                    SizedBox(
                      width: 220,
                      height: 220,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (!widget.reduced)
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    context.gtColors.actionPrimary.withValues(
                                      alpha: .20,
                                    ),
                                    context.gtColors.actionPrimary.withValues(
                                      alpha: 0,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (!widget.reduced)
                            Positioned.fill(
                              child: CustomPaint(
                                key: const ValueKey('achievement-particles'),
                                painter: _RewardParticles(
                                  t,
                                  context.gtColors.actionPrimary,
                                ),
                              ),
                            ),
                          Transform.scale(
                            scale: scale,
                            child: AchievementMedal(
                              rule: widget.rule,
                              unlocked: true,
                              size: 150,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Text('新成就已解锁'),
                    const SizedBox(height: 8),
                    Text(
                      widget.rule.title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(widget.rule.condition, textAlign: TextAlign.center),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          GtDialogAction(
            onPressed: () => Navigator.pop(context),
            role: GtDialogActionRole.primary,
            filled: true,
            label: '收下印章',
          ),
        ],
      ),
    ),
  );
}

class _RewardParticles extends CustomPainter {
  _RewardParticles(this.progress, this.color);
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 1 - progress);
    for (var i = 0; i < 16; i++) {
      final angle = i * math.pi / 8, radius = 65 + progress * 42;
      canvas.drawCircle(
        size.center(Offset.zero) +
            Offset(math.cos(angle), math.sin(angle)) * radius,
        1.5 + (i % 3) * .5,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RewardParticles old) =>
      old.progress != progress || old.color != color;
}
