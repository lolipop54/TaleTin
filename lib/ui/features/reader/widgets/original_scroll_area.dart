import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../platform/channels/original_webview_warmup.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../engine/normalization/locator_mapper.dart';
import '../../../../engine/parsers/epub/locator_dom_point.dart';
import '../../../../engine/selection/original_selection_map.dart';
import '../../../../engine/selection/scroll_selection.dart';
import '../../../../engine/selection/selection_range.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../../../core/widgets/book_loading.dart';
import '../view_models/original_layout_controller.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/automatic_reading.dart';
import 'original_scroll_webview.dart';
import 'original_font_assets.dart';
import 'original_host_controller.dart';
import 'scroll_selection_layer.dart';
import 'reader_display_transition.dart';
import 'reader_information.dart';
import 'reader_performance.dart';
import 'reader_image_viewer.dart';
import 'reader_image_gallery.dart';
import 'simplified_scroll_area.dart' show ScrollInformationPainter;

part 'original_scroll_commands.dart';
part 'original_automatic_motion.dart';
part 'original_scroll_selection.dart';

class OriginalScrollArea extends ConsumerStatefulWidget {
  static Future<NativeReadingFrame?> capture(GlobalKey key) async {
    final state = key.currentState as OriginalScrollAreaState?;
    final controller = state?.host;
    if (state == null || controller == null || !state._ready) return null;
    final image = await OriginalHostController.fromWebView(controller)
        .capture();
    return (image: image, bounds: state._bodyBounds);
  }

  const OriginalScrollArea({
    super.key,
    required this.bookId,
    required this.session,
    required this.settings,
    required this.original,
  });
  final String bookId;
  final ReaderSession session;
  final ReaderSettingsState settings;
  final OriginalLayoutController original;
  @override
  ConsumerState<OriginalScrollArea> createState() => OriginalScrollAreaState();
}

class OriginalScrollAreaState extends ConsumerState<OriginalScrollArea>
    with
        _OriginalScrollCommands,
        _OriginalAutomaticMotion,
        _OriginalScrollSelection {
  @override
  InAppWebViewController? host;
  @override
  bool _loaded = false;
  @override
  int _request = 0;
  int get requestVersion => _request;
  int _presentedRequest = -1;
  @override
  final _maps = <int, ({ChapterContent content, LocatorDomMap map})>{};
  @override
  final _preparing = <int, String>{};
  ScrollHostAssets? _assets;
  final _preparedView = OriginalWebViewWarmup.takeFirstView();
  String? _submitted;
  @override
  bool _ready = false;
  bool get isReady => _ready;
  @visibleForTesting
  Future<String> preparationState() async => jsonEncode({
    'assets': _assets != null,
    'loaded': _loaded,
    'ready': _ready,
    'request': _request,
    'maps': _maps.keys.toList(),
    'steps': _preparing.toString(),
    'submitted': _submitted,
    'positionSteps': widget.original.positionPreparation,
    'web': await host?.evaluateJavascript(
      source:
          'JSON.stringify({url:location.href,state:document.readyState,host:typeof gtScroll,'
          'ready:window.gtScroll?.ready,frames:document.querySelectorAll("iframe").length})',
    ),
  });
  Future<void> volumeTurn(bool forward) async {
    if (!isReady || host == null) return;
    await _automatic.discard();
    await _session.beginManualReading();
    if (!mounted || !isReady) return;
    await host?.evaluateJavascript(
      source:
          'if(gtScroll.ready&&!gtScroll.busy){scrollBy(0,innerHeight*0.85*${forward ? 1 : -1});gtScroll.report();}',
    );
  }

  double? _stableHeight;
  Rect _bodyBounds = Rect.zero;
  @override
  ReaderSessionNotifier get _session =>
      ref.read(readerSessionProvider(widget.bookId).notifier);

  @override
  void initState() {
    super.initState();
    _initAutomatic();
    _initSelection();
    final startup = OriginalWebViewWarmup.ensureReady();
    ScrollHostAssets.load().then((value) async {
      await startup;
      if (mounted) setState(() => _assets = value);
    });
  }

  @override
  Future<Object?> _message(Map<String, dynamic> raw) async {
    if (!mounted || raw['request'] != _request) return null;
    switch (raw['type']) {
      case 'activity':
        if (raw['generation'] == _autoGeneration) {
          _automatic.reportAdvancing(raw['advancing'] == true);
        }
      case 'need':
        final meta = await measureReader(
          'original.scroll.meta',
          () => _meta(raw['index'] as int),
        );
        await _syncDecorations();
        return meta;
      case 'window':
        // 短章会同时保留多章，对照表必须跟实际窗口走，不能仍按前后各一章删。
        final indices = (raw['indices'] as List).cast<int>().toSet();
        _maps.removeWhere((index, _) => !indices.contains(index));
      case 'ready':
        final controller = host;
        if (controller == null) return null;
        await OriginalHostController.fromWebView(controller).presented();
        if (!mounted || raw['request'] != _request) return null;
        _presentedRequest = _request;
        _preparedLayout = _requestedLayout;
        setState(() => _ready = true);
        // 补远端章节期间当前画面仍然有效，目标确认无需等离屏加载。
        final point = await host?.evaluateJavascript(
          source: 'JSON.stringify(gtScroll.anchor())',
        );
        if (point is String) {
          await _message({
            'type': 'position',
            'request': raw['request'],
            'point': jsonDecode(point),
          });
        }
        await _syncDecorations();
      case 'position':
        if (_presentedRequest != _request) return null;
        final point = Map<String, dynamic>.from(raw['point'] as Map);
        final index = point['index'] as int;
        final entry = _maps[index];
        if (entry == null) return null;
        final Locator locator;
        if (point['image'] case final int image) {
          final blocks = entry.content.blocks
              .where((b) => b.kind == BlockKind.image)
              .toList();
          if (image >= blocks.length) return null;
          locator = LocatorMapper(
            bookId: widget.bookId,
            contentVersion: widget.session.book.contentVersion,
            chapterId: entry.content.chapterId,
          ).at(blocks[image], 0, affinity: LocatorAffinity.before);
        } else {
          locator = entry.map.locatorOf(point);
        }
        if (_session.reportScrollPosition(
          entry.content,
          locator,
          jumpToken: _appliedJump,
        )) {
          _session.completeAnnotationLanding();
        }
        _selectionMotion.value++;
      case 'settled':
        await _session.persist();
      case 'manual':
        await _session.beginManualReading();
      case 'longpress':
        await _selectionKey.currentState?.begin(
          Offset((raw['x'] as num).toDouble(), (raw['y'] as num).toDouble()),
        );
      case 'tap':
        final handled =
            await _selectionKey.currentState?.tap(
              Offset(
                (raw['x'] as num).toDouble(),
                (raw['y'] as num).toDouble(),
              ),
            ) ??
            false;
        if (!handled &&
            mounted &&
            await _selectionBackend.contentTap?.call(
                  Offset(
                    (raw['x'] as num).toDouble(),
                    (raw['y'] as num).toDouble(),
                  ),
                ) !=
                true &&
            mounted) {
          _automatic.centerTap();
        }
      case 'error':
        _automatic.finish('章节读取失败，已暂停；可再次开始重试');
      case 'end':
        _automatic.finish('已到全书末尾');
      case 'image':
        await _session.beginManualReading();
        if (!mounted) return null;
        final url = raw['href'] as String;
        if (await tryReaderImageGallery(
          context,
          ref,
          widget.bookId,
          galleryResourcePath(url),
          chapterId: raw['index'] is int
              ? widget.session.chapters[raw['index'] as int].id
              : null,
        )) {
          return null;
        }
        if (!mounted) return null;
        final bytes = await widget.original.imageBytes(url);
        if (!mounted) return null;
        if (bytes == null) {
          ref.read(readerProvider.notifier).showNotice('图片无法打开，请重试');
        } else if (Uri.parse(url).path.toLowerCase().endsWith('.svg')) {
          await showReaderSvg(context, SvgBytesLoader(bytes));
        } else {
          await showReaderImage(context, MemoryImage(bytes));
        }
      case 'link':
        final href = Uri.parse(raw['href'] as String);
        final target = widget.original.source.resolveLink(
          widget.original.source.chapterUrl(raw['index'] as int),
          href.toString(),
        );
        if (target != null) {
          await _session.goToChapterFromToc(
            widget.session.chapters[target.ordinal].id,
            anchorId: target.fragment,
          );
        }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final settings = widget.settings.settings;
      final info = readerInformation(
        context,
        ref,
        widget.session,
        settings,
        widget.settings.theme,
        widget.session.chapterIndex,
        widget.session.chapterProgress,
      );
      if (MediaQuery.viewInsetsOf(context).bottom == 0) {
        _stableHeight = box.maxHeight;
      }
      final height = _stableHeight ?? box.maxHeight;
      final left = math.max(0.0, (box.maxWidth - GtSize.readingMaxWidth) / 2);
      _bodyBounds = Rect.fromLTWH(
        left,
        info.top,
        box.maxWidth - 2 * left,
        height - info.top - info.bottom,
      );
      final options = <String, Object?>{
        'fontSizePx': MediaQuery.textScalerOf(context)
            .scale(settings.fontSize.toDouble()),
        'marginPx': settings.horizontalPadding,
        'indent': settings.indent,
        'fontFamily': settings.useOriginalFont
            ? ''
            : settings.fontFamily ?? 'sans-serif',
        'fontWeight': settings.fontWeight,
        'lineHeight': settings.lineHeight,
        'paragraphGapEm': settings.paragraphGapEm,
        'colors': {
          'bg': hexOf(widget.settings.theme.background),
          'text': hexOf(widget.settings.theme.primary),
          'link': hexOf(readingLinkColor(widget.settings.theme)),
        },
      };
      final layoutSignature = '${jsonEncode(options)}|${box.maxWidth}|$height';
      final key = '$layoutSignature|${widget.session.scrollJump?.token}';
      if (_loaded && _submitted != key) {
        _submitted = key;
        // 主题／显示切换的遮盖必须等待本次网页绘制，不能沿用上一页的 ready。
        _ready = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _submitted == key) {
            unawaited(_open(options, layoutSignature));
          }
        });
      }
      return Stack(
        children: [
          if (_assets != null)
            Positioned(
              top: info.top,
              bottom: info.bottom,
              left: math.max(0, (box.maxWidth - GtSize.readingMaxWidth) / 2),
              right: math.max(0, (box.maxWidth - GtSize.readingMaxWidth) / 2),
              child: ScrollSelectionLayer(
                key: _selectionKey,
                bookId: widget.bookId,
                backend: _selectionBackend,
                theme: widget.settings.theme,
                child: OriginalScrollWebView(
                  preparedView: _preparedView,
                  source: widget.original.source,
                  assets: _assets!,
                  onController: (value) => host = value,
                  onLoaded: () {
                    if (mounted) setState(() => _loaded = true);
                  },
                  onMessage: _message,
                ),
              ),
            ),
          // WebView 必须先参与绘制才能得到真实视口尺寸；用稳定封面遮住准备过程。
          if (!_ready)
            Positioned.fill(
              child: ColoredBox(
                color: widget.settings.theme.background,
                child: const Center(child: BookLoading()),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: ScrollInformationPainter(info)),
            ),
          ),
        ],
      );
    },
  );

  @override
  void dispose() {
    if (_preparedView?.isRunning() ?? false) {
      unawaited(_preparedView!.dispose());
    }
    _disposeAutomatic();
    _selectionMotion.dispose();
    _request++;
    _maps.clear();
    host = null;
    super.dispose();
  }
}
