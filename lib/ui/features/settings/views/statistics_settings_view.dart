import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/statistics_settings_providers.dart';
import '../widgets/settings_action.dart';
import '../widgets/settings_page.dart';
import '../widgets/settings_row.dart';

class StatisticsSettingsView extends ConsumerStatefulWidget {
  const StatisticsSettingsView({super.key});
  @override
  ConsumerState<StatisticsSettingsView> createState() =>
      _StatisticsSettingsState();
}

class _StatisticsSettingsState extends ConsumerState<StatisticsSettingsView> {
  bool resetting = false;
  @override
  Widget build(BuildContext context) {
    final data = ref.watch(statisticsSettingsProvider);
    final settings = data.value;
    final vm = ref.read(statisticsSettingsProvider.notifier);
    return Scaffold(
      appBar: GtAppBar(title: const Text('阅读统计设置')),
      body: SafeArea(
        child: settings == null
            ? Center(
                child: data.hasError
                    ? GtButton(
                        onPressed: () =>
                            ref.invalidate(statisticsSettingsProvider),
                        child: const Text('读取失败，重试'),
                      )
                    : const SizedBox.shrink(),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    '计时规则',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    '只在前台看正文时计时，打开面板或长时间无操作会暂停。自动阅读按实际推进计时，听书按实际发声计时，后台听书也会记录。计时会定期保存，暂停或退出时立即保存。',
                  ),
                  const SizedBox(height: 20),
                  SettingsRow(
                    label: '无操作暂停计时',
                    value: '${settings.idleMinutes} 分钟',
                    onTap: () => openSettingsPage(
                      context,
                      SettingsChoices<int>(
                        title: '无操作多久暂停看书计时',
                        options: const [2, 5, 10],
                        label: (v) => '$v 分钟',
                        selected: (ref) => ref
                            .watch(statisticsSettingsProvider)
                            .requireValue
                            .idleMinutes,
                        save: (ref, v) => ref
                            .read(statisticsSettingsProvider.notifier)
                            .change(idleMinutes: v),
                      ),
                    ),
                  ),
                  SettingsRow(
                    divider: false,
                    label: '听书时长计入总览',
                    trailing: GtSwitch(
                      value: settings.includeAudio,
                      onChanged: (v) => saveSetting(
                        context,
                        () => vm.change(includeAudio: v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  GtButton.outlined(
                    onPressed: resetting ? null : _reset,
                    child: Text(resetting ? '正在重置…' : '重置阅读统计'),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认重置阅读统计？'),
        content: const SingleChildScrollView(
          child: Text('将清除看书和听书时长、连续阅读天数及相关徽章。书籍、阅读位置、笔记、读完记录和设置会保留。重置后无法撤销。'),
        ),
        actions: [
          GtDialogAction(
            onPressed: () => Navigator.pop(context, false),
            label: '取消',
          ),
          GtDialogAction(
            role: GtDialogActionRole.danger,
            filled: true,
            onPressed: () => Navigator.pop(context, true),
            label: '确认重置',
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => resetting = true);
    try {
      await ref.read(resetReadingStatisticsProvider).run();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('阅读统计已重置')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('重置未完成，请重试')));
      }
    } finally {
      if (mounted) setState(() => resetting = false);
    }
  }
}
