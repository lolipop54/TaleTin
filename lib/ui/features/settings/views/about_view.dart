import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../platform/channels/reading_window.dart';

/// 版本来自手机已安装包，不能使用写死的展示字符串。
final appInformationProvider = FutureProvider.autoDispose<Map<String, Object?>>(
  (ref) async => (await ReadingWindow.channel.invokeMapMethod<String, Object?>(
    'appInfo',
  ))!,
);

class AboutView extends ConsumerWidget {
  const AboutView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appInformationProvider), info = state.value;
    return Scaffold(
      appBar: GtAppBar(title: const Text('关于 TaleTin')),
      body: SafeArea(
        child: info == null
            ? Center(
                child: state.hasError
                    ? GtButton(
                        onPressed: () => ref.invalidate(appInformationProvider),
                        child: const Text('版本读取失败，重试'),
                      )
                    : const SizedBox.shrink(),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'TaleTin v${info['version']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  Text('支持格式', style: Theme.of(context).textTheme.titleMedium),
                  const Text(
                    'EPUB、TXT、MOBI、AZW3 与 PDF。\n\n'
                    'EPUB、MOBI 和 AZW3 可选「简化排版」或「原书排版」，阅读进度、书签、笔记在两种模式间互通；'
                    'TXT 使用简化排版，导入时可确认文字编码和章节规则。\n\n'
                    'PDF 可选「电子书模式」或「PDF模式」；电子书模式读取文字层和图片，扫描页直接显示整页图片，不进行文字识别。\n\n'
                    '加密或带 DRM 保护的书无法导入；固定版式 EPUB（漫画类常见）不做重排，按单页图片顺排显示。',
                  ),
                  const SizedBox(height: 24),
                  Text('隐私说明', style: Theme.of(context).textTheme.titleMedium),
                  const Text(
                    '书籍、阅读进度、书签、笔记、统计和设置都保存在本机，'
                    '没有账号，也没有云同步，不会上传到任何服务器。\n\n'
                    '导入书籍和导出备份都由你在系统文件选择器中指定文件与位置。\n\n'
                    '原书排版使用内置浏览器组件还原原书样式，书中的脚本不会执行，外部网络资源不会加载；'
                    '应用声明的网络权限是组件本身的要求，不代表会联网。\n\n'
                    '听书调用手机已安装的系统语音引擎，应用不内置语音模型，可断网试听确认是否完全离线。\n\n'
                    '清理缓存不会删除书籍和笔记；卸载应用或清除应用数据会移除本机数据。',
                  ),
                  const SizedBox(height: 24),
                  GtButton.tonal(
                    onPressed: () => showLicensePage(
                      context: context,
                      applicationName: 'TaleTin',
                      applicationVersion: '${info['version']}+${info['build']}',
                    ),
                    child: const Text('查看开源许可'),
                  ),
                ],
              ),
      ),
    );
  }
}
