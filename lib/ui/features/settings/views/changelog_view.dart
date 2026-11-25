import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_app_bar.dart';
import '../../../core/widgets/gt_button.dart';
import '../widgets/windows_settings_layout.dart';

typedef ChangelogContent = ({String markdown, Map<String, Size?> imageSizes});

final changelogProvider = FutureProvider.autoDispose<ChangelogContent>((
  ref,
) async {
  final markdown = await rootBundle.loadString('assets/更新日志.md');
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  // 只准备正文实际引用的图片，同时记录尺寸，图片滚入屏幕时不挤动文字。
  final assets = _imageAssets(document.parse(markdown)).toSet();
  final sizes = await Future.wait(assets.map(_prepareImage));
  return (markdown: markdown, imageSizes: Map.fromIterables(assets, sizes));
});

Iterable<String> _imageAssets(List<md.Node> nodes) sync* {
  for (final element in nodes.whereType<md.Element>()) {
    if (element.tag == 'img') {
      final asset = _imageAsset(Uri.tryParse(element.attributes['src'] ?? ''));
      if (asset != null) yield asset;
    }
    yield* _imageAssets(element.children ?? const []);
  }
}

String? _imageAsset(Uri? uri) {
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  final segments = uri.pathSegments;
  if (segments.length != 2 || segments.first != 'changelog_images') return null;
  return 'assets/${segments.join('/')}';
}

Future<Size?> _prepareImage(String asset) async {
  final stream = ExactAssetImage(asset).resolve(ImageConfiguration.empty);
  final ready = Completer<Size?>();
  final listener = ImageStreamListener(
    (info, _) {
      if (!ready.isCompleted) {
        ready.complete(
          Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
      }
      info.dispose();
    },
    onError: (_, _) {
      if (!ready.isCompleted) ready.complete(null);
    },
  );
  stream.addListener(listener);
  try {
    return await ready.future;
  } finally {
    stream.removeListener(listener);
  }
}

class ChangelogView extends ConsumerWidget {
  const ChangelogView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.gtColors;
    final content = ref.watch(changelogProvider).requireValue;

    return Scaffold(
      appBar: GtAppBar.settings(
        title: const Text('更新日志'),
        actions: [
          GtButton(
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(0, 48)),
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: GtSpacing.s2),
              ),
            ),
            onPressed: () => launchUrl(
              Uri.https('github.com', '/lolipop54/TaleTin/releases'),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('GitHub发布页', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: GtSpacing.s2),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: WindowsSettingsPane.contains(context)
                  ? double.infinity
                  : 680,
            ),
            child: Markdown(
              data: content.markdown,
              padding: const EdgeInsets.fromLTRB(
                GtSpacing.s5,
                GtSpacing.s4,
                GtSpacing.s5,
                GtSpacing.s6,
              ),
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                horizontalRuleDecoration: BoxDecoration(
                  border: Border(top: Divider.createBorderSide(context)),
                ),
                a: TextStyle(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
                p: GtText.body(colors.textPrimary),
                h2: GtText.pageTitle(colors.textPrimary),
                h3: GtText.body(colors.textPrimary, weight: FontWeight.w600),
                textScaler: MediaQuery.textScalerOf(context),
              ),
              imageBuilder: (uri, _, alt) {
                final asset = _imageAsset(uri);
                final size = content.imageSizes[asset];
                if (asset == null || size == null) {
                  return Text(alt?.isNotEmpty == true ? alt! : '图片加载失败');
                }
                return SizedBox(
                  width: math.min(size.width, 360),
                  child: AspectRatio(
                    aspectRatio: size.aspectRatio,
                    child: Image(
                      image: ExactAssetImage(asset),
                      semanticLabel: alt,
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
              onTapLink: (_, href, _) async {
                final uri = Uri.tryParse(href ?? '');
                if (uri != null && uri.scheme == 'https') {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}
