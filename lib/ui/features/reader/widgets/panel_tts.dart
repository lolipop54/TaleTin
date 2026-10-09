import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/tts_state.dart';
import '../view_models/listening_panel_view_model.dart';
import '../view_models/listening_view_state.dart';
import '../view_models/reader_session_view_model.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../view_models/reader_view_model.dart';
import 'reader_sheet.dart';
import 'listening_settings_controls.dart';
import 'listening_timer_control.dart';
import '../../../core/widgets/gt_icon.dart';

/// 听书面板（参考图 03-4）。
/// 当前句段、播放控制、音色、语速、睡眠定时。
/// 所有播放信息来自应用级服务，首次准备完成后整体展示。
class PanelTts extends ConsumerWidget {
  const PanelTts({super.key, required this.bookId});

  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.read(readerProvider.notifier);
    final colors = context.gtColors;
    final id = bookId;
    final session = ref.watch(readerSessionProvider(id)).value;
    final all = ref.watch(listeningViewStateProvider).value;
    final speech = all?.bookId == id ? all! : const ListeningState();
    final commands = ref.watch(listeningPanelProvider(id));
    final ready = session != null && all != null;
    final canPlay = all?.voice != null;
    return ReaderSheet(
      title: '听书',
      maxHeightFactor: 0.78,
      onClose: vm.closePanel,
      child: !ready
          ? const SizedBox.shrink()
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: GtSpacing.s2),
                  Text(
                    speech.chapterTitle.isEmpty
                        ? session.chapter.title
                        : speech.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GtText.body(colors.textSecondary)
                        .copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: GtSpacing.s2),
                  // 始终留出三行，短句、长句和换章不会把面板与按钮顶来顶去。
                  SizedBox(
                    key: const Key('tts-sentence-area'),
                    width: double.infinity,
                    height:
                        MediaQuery.textScalerOf(context).scale(16) * 1.35 * 3 +
                        4,
                    child: Text(
                      speech.currentSentence.isEmpty
                          ? '从当前阅读位置开始朗读'
                          : speech.currentSentence,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: GtText.sectionTitle(colors.textPrimary)
                          .copyWith(fontSize: 16),
                    ),
                  ),
                  const SizedBox(height: GtSpacing.s3),
                  if (all.error != null)
                    Text(
                      all.error!,
                      style: GtText.caption(colors.textSecondary),
                    ),
                  if (speech.notice != null)
                    Text(
                      speech.notice!,
                      style: GtText.caption(colors.textSecondary),
                    ),
                  // 播放控制
                  Row(
                    children: [
                      _TransportControl(
                        icon: GtIcons.skipPrevious,
                        label: '上一章',
                        color: colors.textPrimary,
                        onTap: speech.hasSession
                            ? () => commands.chapter(-1)
                            : null,
                      ),
                      // 播放/暂停主按钮
                      Expanded(
                        child: Column(
                          children: [
                            GtButton.raw(
                              key: const Key('tts-toggle'),
                              onPressed: canPlay ? commands.toggle : null,
                              customBorder: const CircleBorder(),
                              child: Container(
                                width: 60,
                                height: 60,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: canPlay
                                      ? colors.actionPrimary
                                      : colors.textMuted,
                                ),
                                child: GtIcon(
                                  speech.desiredPlaying
                                      ? GtIcons.pause
                                      : GtIcons.play,
                                  color: colors.onPrimary,
                                  size: 30,
                                ),
                              ),
                            ),
                            const SizedBox(height: GtSpacing.s1),
                            Text(
                              speech.desiredPlaying
                                  ? '暂停'
                                  : speech.hasSession
                                  ? '继续'
                                  : '开始',
                              style: GtText.caption(colors.textSecondary)
                                  .copyWith(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      _TransportControl(
                        icon: GtIcons.skipNext,
                        label: '下一章',
                        color: colors.textPrimary,
                        onTap: speech.hasSession
                            ? () => commands.chapter(1)
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: GtSpacing.s2),
                  Center(
                    child: GtButton(
                      onPressed: speech.hasSession ? commands.stop : null,
                      child: const Text('停止听书'),
                    ),
                  ),
                  Container(height: 1, color: colors.borderSubtle),
                  ListeningSettingsControls(bookId: id),
                  ListeningTimerControl(bookId: id, state: speech),
                  const SizedBox(height: GtSpacing.s5),
                ],
              ),
            ),
    );
  }
}

/// 播放控制小按钮（图标 + 下方文字）。
class _TransportControl extends StatelessWidget {
  const _TransportControl({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GtButton.raw(
        onPressed: onTap,
        borderRadius: BorderRadius.circular(GtRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: GtSpacing.s2),
          child: Column(
            children: [
              GtIcon(icon, size: 26, color: color),
              const SizedBox(height: GtSpacing.s1),
              Text(label, style: GtText.caption(color).copyWith(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
