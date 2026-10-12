import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../../domain/models/tts_state.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';
import '../../reader/widgets/listening_option_header.dart';
import '../../reader/widgets/reader_sheet.dart';
import '../../reader/widgets/reader_option_autosave.dart';
import '../../reader/view_models/listening_voice_choices.dart';
import '../../reader/view_models/listening_view_state.dart';

/// 与阅读中的试听弹层共用真实引擎和音色数据，设置页只保留选择功能。
class ListeningVoiceView extends ConsumerStatefulWidget {
  const ListeningVoiceView({super.key, this.sheet = false});
  final bool sheet;
  @override
  ConsumerState<ListeningVoiceView> createState() => _ListeningVoiceViewState();
}

class _ListeningVoiceViewState extends ConsumerState<ListeningVoiceView> {
  late final AppLifecycleListener _lifecycle;
  ScrollController? _scroll;
  String? _engine;
  bool _settingsOpened = false;
  OfflineVoice? _draft;
  OfflineVoice? _pendingVoice;

  Future<void> _choose(OfflineVoice voice) async {
    setState(() => _pendingVoice = voice);
    await ref.read(listeningVoiceChoicesProvider.notifier).choose(voice);
    if (mounted) setState(() => _pendingVoice = null);
  }

  Future<bool> _saveSelection() async {
    final data = ref.read(listeningVoiceChoicesProvider).value;
    if (data?.busy == true) return false;
    if (_draft == null) return true;
    final current = ref.read(listeningViewStateProvider).value?.voice;
    if (_draft!.enginePackage == current?.enginePackage &&
        _draft!.voiceId == current?.voiceId &&
        _draft!.locale == current?.locale) {
      return true;
    }
    await ref.read(listeningVoiceChoicesProvider.notifier).choose(_draft!);
    return ref.read(listeningVoiceChoicesProvider).value?.error == null;
  }

  @override
  void initState() {
    super.initState();
    _draft = ref.read(listeningViewStateProvider).value?.voice;
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!mounted || !_settingsOpened) return;
        _settingsOpened = false;
        ref
            .read(listeningVoiceChoicesProvider.notifier)
            .detect(ref.read(listeningVoiceChoicesProvider).value?.engine);
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final choices = ref.watch(listeningVoiceChoicesProvider);
    final data = choices.value;
    final vm = ref.read(listeningVoiceChoicesProvider.notifier);
    final selected = widget.sheet
        ? _draft
        : _pendingVoice ?? ref.watch(listeningViewStateProvider).value?.voice;
    // 验证状态变化不改变音色身份，仍按引擎、ID 和语言显示选中项。
    bool isSelected(OfflineVoice voice) =>
        voice.enginePackage == selected?.enginePackage &&
        voice.voiceId == selected?.voiceId &&
        voice.locale == selected?.locale;
    final c = context.gtColors;
    // 已安装且无需联网的音色才可在这里选择；不以提示文字伪装不可用选项。
    final voices =
        data?.voices
            .where((v) => !v.requiresNetwork && v.isInstalled)
            .toList() ??
        [];
    final headerTitle = FPopoverMenu(
      menuBuilder: (context, controller, _) => [
        FItemGroup(
          children: [
            for (final engine in data?.engines ?? [])
              FItem(
                onPress: data!.busy
                    ? null
                    : () async {
                        final detection = vm.detect(engine.packageName);
                        await controller.hide();
                        await detection;
                      },
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        engine.label,
                        style: TextStyle(
                          fontWeight: FontWeight.normal,
                          color: engine.packageName == data.engine
                              ? c.actionPrimary
                              : c.textPrimary,
                        ),
                      ),
                    ),
                    if (engine.packageName == data.engine)
                      GtIcon(GtIcons.check, color: c.actionPrimary, size: 20),
                  ],
                ),
              ),
          ],
        ),
      ],
      builder: (context, controller, child) => GtButton.raw(
        onPressed: data == null || data.busy ? null : controller.toggle,
        child: child!,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              data?.engines
                      .where((e) => e.packageName == data.engine)
                      .firstOrNull
                      ?.label ??
                  '语音引擎',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          GtIcon(GtIcons.chevronDown, size: 20, color: c.textPrimary),
        ],
      ),
    );
    final page = Scaffold(
      backgroundColor: widget.sheet ? ReaderSheet.backgroundOf(context) : null,
      appBar: widget.sheet
          ? ListeningOptionHeader(title: headerTitle)
          : GtAppBar(title: headerTitle),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: data == null
                  ? Center(
                      child: choices.hasError
                          ? GtButton(
                              onPressed: () =>
                                  ref.invalidate(listeningVoiceChoicesProvider),
                              child: const Text('检测失败，点击重试'),
                            )
                          : const SizedBox.shrink(),
                    )
                  : data.loadingVoices
                  ? const Center(child: Text('加载音色中...'))
                  : voices.isEmpty
                  ? const Center(child: Text('暂无可用的离线音色'))
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final height = math.max(
                          48.0,
                          MediaQuery.textScalerOf(context).scale(15) * 1.5 + 16,
                        );
                        if (_scroll == null || _engine != data.engine) {
                          final old = _scroll;
                          final index = voices.indexWhere(isSelected);
                          // 在列表首次布局前给出位置，避免先显示顶部再滚到选中项。
                          _scroll = ScrollController(
                            initialScrollOffset: (math.max(0, index) * height)
                                .clamp(
                                  0.0,
                                  math.max(
                                    0.0,
                                    voices.length * height -
                                        constraints.maxHeight,
                                  ),
                                ),
                          );
                          _engine = data.engine;
                          if (old != null) {
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => old.dispose(),
                            );
                          }
                        }
                        return ListView.builder(
                          controller: _scroll,
                          physics: const ClampingScrollPhysics(),
                          itemExtent: height,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: voices.length,
                          itemBuilder: (_, index) {
                            final voice = voices[index];
                            final active = isSelected(voice);
                            return Material(
                              color: active
                                  ? widget.sheet
                                        ? Color.lerp(
                                            ReaderSheet.backgroundOf(context),
                                            c.textPrimary,
                                            .06,
                                          )
                                        : c.subtle
                                  : Colors.transparent,
                              child: GtButton.raw(
                                onPressed: data.busy
                                    ? null
                                    : () => widget.sheet
                                          ? setState(() => _draft = voice)
                                          : _choose(voice),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        child: Text(
                                          '${voice.displayName} · ${voice.locale}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GtText.body(
                                            active
                                                ? c.actionPrimary
                                                : c.textPrimary,
                                          ),
                                        ),
                                      ),
                                    ),
                                    GtButton.icon(
                                      tooltip: '试听',
                                      onPressed: data.busy
                                          ? null
                                          : () => vm.preview(voice),
                                      icon: Icon(
                                        Icons.play_circle_filled,
                                        color: c.actionPrimary,
                                        size: 26,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
            if (data?.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(data!.error!, style: GtText.body(c.danger)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: GtButton(
                onPressed: data == null || data.busy
                    ? null
                    : () {
                        _settingsOpened = true;
                        vm.openSettings(false);
                      },
                child: const Text('系统语音设置'),
              ),
            ),
          ],
        ),
      ),
    );
    return widget.sheet
        ? ReaderOptionAutosave(save: _saveSelection, child: page)
        : page;
  }
}
