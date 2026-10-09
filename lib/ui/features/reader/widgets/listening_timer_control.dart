import 'package:taletin/ui/core/widgets/gt_list_button.dart';
import 'package:flutter/material.dart';

import '../../settings/widgets/settings_slider.dart';
import 'reader_option_autosave.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/tts_state.dart';
import '../../../../app/di/app_providers.dart';
import '../../../core/theme/gt_tokens.dart';
import 'listening_option_sheet.dart';
import 'reader_compact_option.dart';
import 'reader_sheet.dart';

String listeningTimerLabel(ListeningState state) {
  if (state.sleepPolicy.kind == SleepPolicyKind.off) return '不定时';
  if (state.sleepPolicy.kind == SleepPolicyKind.chapterEnd) return '读完本章';
  final remaining = state.remaining;
  if (remaining == null) return '正在设置…';
  if (!state.hasSession) return '${state.sleepPolicy.minutes} 分钟（开始听书后计时）';
  final seconds = (remaining.inMilliseconds / 1000).ceil().clamp(0, 10800);
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')} 后停止';
}

class ListeningTimerControl extends ConsumerWidget {
  const ListeningTimerControl({
    super.key,
    required this.bookId,
    required this.state,
  });
  final String bookId;
  final ListeningState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(listeningServiceProvider);
    return Material(
      type: MaterialType.transparency,
      child: GtListButton(
        contentPadding: EdgeInsets.zero,
        title: const Text('睡眠定时', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          listeningTimerLabel(state),
          style: TextStyle(fontSize: 12),
        ),
        trailing: const Text('设置'),
        onPressed: () async {
          final repository = ref.read(listeningTimerRepositoryProvider);
          final remembered = await repository.loadMinutes();
          if (!context.mounted) return;
          await showListeningOption<SleepPolicy>(
            context,
            ref,
            (_) => ListeningTimerDialog(
              policy: remembered == null
                  ? state.sleepPolicy
                  : remembered == 0
                  ? const SleepPolicy.off()
                  : SleepPolicy.minutes(remembered),
              save: (policy) async {
                await repository.saveMinutes(policy.minutes);
                await service.setSleepPolicy(policy, bookId: bookId, restartTimer: true);
              },
            ),
            bookId: bookId,
            shrinkWrap: true,
          );
        },
      ),
    );
  }
}

class ListeningTimerDialog extends StatefulWidget {
  const ListeningTimerDialog({super.key, required this.policy, this.save});
  final SleepPolicy policy;
  final Future<void> Function(SleepPolicy)? save;
  @override
  State<ListeningTimerDialog> createState() => _TimerDialogState();
}

class _TimerDialogState extends State<ListeningTimerDialog> {
  late int _minutes = widget.policy.kind == SleepPolicyKind.minutes
      ? widget.policy.minutes
      : 0;
  String? _error;
  bool _saving = false;

  Future<bool> _saveSelection() async {
    setState(() => _saving = true);
    try {
      await widget.save?.call(
        _minutes == 0 ? const SleepPolicy.off() : SleepPolicy.minutes(_minutes),
      );
      return true;
    } catch (_) {
      if (mounted) setState(() => _error = '定时未保存，请重试');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ReaderOptionAutosave(
    save: _saveSelection,
    child: ReaderCompactOption(
      title: '睡眠定时',
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SettingsSlider(
                key: const Key('tts-timer-minutes'),
      labelPosition: SliderLabelPosition.above,
                compact: true,
                trackThickness: GtSliderSize.trackThicknessSmall,
                thumbRadius: GtSliderSize.thumbRadiusSmall,
                backgroundColor: ReaderSheet.backgroundOf(context),
                label: _minutes == 0 ? '定时时长：不定时' : '定时时长：$_minutes 分钟',
                labelStyle: const TextStyle(fontSize: 14),
                numberStyle: TextStyle(fontSize: 10, color: context.gtColors.textPrimary),
                value: _minutes.toDouble(),
                min: 0,
                max: 180,
                divisions: 180,
                format: (v) => '${v.round()}',
                onPreview: (value) {
                  if (value != null) {
                    setState(() {
                      _minutes = value.round();
                      _error = null;
                    });
                  }
                },
                save: _saving
                    ? null
                    : (value) async {
                        setState(() => _minutes = value.round());
                      },
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text('不定时'), Text('180 分钟')],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
