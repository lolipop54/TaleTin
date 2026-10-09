/// 原书排版模式的桥封装（计划 3.5 / 第 4 节）。
///
/// 界面只跟这个类说话：
/// - 宿主页（WebView 里的 host.js）上报的原始消息在这里变成**强类型事件**，
///   阅读页按事件处理，不再到处解析字符串键；
/// - 命令（翻页、定位、样式）经由它转给宿主页；
/// - 它同时持有这一本书的原书内容会话（[EpubSourceSession]），负责关闭归档句柄。
///
/// 边界（计划第 2 节的分工原则）：这里不保存任何业务数据。章序、位置、进度都在
/// Dart 侧的会话里，宿主页只报「页序 + 比例 + 页首文字」。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../data/services/epub_source_repository.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../engine/parsers/epub/locator_dom_point.dart';
import '../widgets/original_host_controller.dart';
import 'reader_session_view_model.dart';

/// 宿主页上报的事件（计划 3.5 的消息表的强类型版本）。
sealed class OriginalHostEvent {
  const OriginalHostEvent({required this.chapterIndex});

  /// 上报时阅读页正在显示的那一章（宿主页不跨章，章序由 Dart 补上）
  final int chapterIndex;
}

/// 文档就绪（还没分栏）
class HostReady extends OriginalHostEvent {
  const HostReady({required super.chapterIndex, required this.pageCount});

  final int pageCount;
}

/// 分栏完成（页数可用）：换章后首次可读的信号
class HostPaginated extends OriginalHostEvent {
  const HostPaginated({required super.chapterIndex, required this.pageCount});

  final int pageCount;
}

/// 位置上报（翻页或重排之后）
class HostRelocate extends OriginalHostEvent {
  const HostRelocate({
    required super.chapterIndex,
    required this.page,
    required this.pageCount,
    required this.fraction,
    required this.firstText,
  });

  final int page;
  final int pageCount;

  /// 章内比例 0–1（排版的临时结果，不落盘）
  final double fraction;

  /// 页首文字（换算回 `Locator` 的主要依据）
  final String firstText;
}

/// 翻到第几页了（翻页动画一开始就报，不等完整的位置上报）。
///
/// 完整上报要遍历元素算页首文字与比例（强制布局），只能等动画结束；但「现在到没到
/// 章末」必须马上知道——否则甩得快的时候边界判定慢半拍，那一下拖动会被当成章内拖动。
class HostPageTurn extends OriginalHostEvent {
  const HostPageTurn({
    required super.chapterIndex,
    required this.page,
    required this.pageCount,
  });

  final int page;
  final int pageCount;
}

/// 章边界：章首再往前 / 章末再往后
class HostBoundary extends OriginalHostEvent {
  const HostBoundary({
    required super.chapterIndex,
    required this.atStart,
    required this.viaSettle,
  });

  final bool atStart;

  /// 这条边界是不是「拖动松手」撞出来的（点击翻页撞出来的是 false）。
  /// 拖动撞出来的要接着做滑动换章，点击的交由换章流程直接切。
  final bool viaSettle;
}

/// 书内链接被点了（交 Dart 决定换章还是锚点跳转）
class HostLink extends OriginalHostEvent {
  const HostLink({required super.chapterIndex, required this.href});

  final String href;
}

/// 宿主页报错（加载或排版失败）
class HostError extends OriginalHostEvent {
  const HostError({required super.chapterIndex, required this.message});

  final String message;
}

/// 原始消息 → 事件；认不出来或与阅读无关的类型（centerTap 等）返回 null。
///
/// 字段缺失或类型不对一律退回默认值：这些消息跨语言边界而来，
/// 宁可有一样东西显示不准，也不能让阅读页报错。
OriginalHostEvent? parseHostEvent(
  Map<String, Object?> raw, {
  required int chapterIndex,
}) {
  int intOf(String key) {
    final value = raw[key];
    return value is num ? value.toInt() : 0;
  }

  double doubleOf(String key) {
    final value = raw[key];
    return value is num ? value.toDouble() : 0;
  }

  String stringOf(String key) {
    final value = raw[key];
    return value is String ? value : '';
  }

  switch (raw['type']) {
    case 'ready':
      return HostReady(chapterIndex: chapterIndex, pageCount: intOf('pages'));
    case 'paginated':
      return HostPaginated(
        chapterIndex: chapterIndex,
        pageCount: intOf('pages'),
      );
    case 'relocate':
      return HostRelocate(
        chapterIndex: chapterIndex,
        page: intOf('page'),
        pageCount: intOf('pages'),
        fraction: doubleOf('fraction'),
        firstText: stringOf('firstText'),
      );
    case 'page':
      return HostPageTurn(
        chapterIndex: chapterIndex,
        page: intOf('page'),
        pageCount: intOf('pages'),
      );
    case 'boundary':
      return HostBoundary(
        chapterIndex: chapterIndex,
        atStart: raw['edge'] == 'start',
        viaSettle: raw['via'] == 'settle',
      );
    case 'link':
      return HostLink(chapterIndex: chapterIndex, href: stringOf('href'));
    case 'error':
      return HostError(chapterIndex: chapterIndex, message: stringOf('message'));
  }
  return null;
}

/// 一本书的原书排版桥。
class OriginalLayoutController {
  OriginalLayoutController({required this.bookId, required this.source});

  final String bookId;

  /// 原书内容会话（`source.epub` 的归档句柄）；由本控制器负责关闭
  final EpubSourceSession source;

  /// 沿用本书本地资源检查，不允许查看器绕过 WebView 加载外网图片。
  Future<Uint8List?> imageBytes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || source.entryPathOf(uri) == null) return null;
    final resource = await source.resourceFor(uri);
    return resource?.contentType.startsWith('image/') == true
        ? resource!.bytes : null;
  }

  // source 已隔离 bookId/contentVersion；映射规则版本参与键，最多保留三个资源。
  final _domMaps = <String, Future<LocatorDomMap>>{};
  Future<LocatorDomMap> positionMap(
    int index,
    String href,
    ChapterContent content,
    Locator locator,
  ) {
    final key = '1:$index:$href';
    return _domMaps.putIfAbsent(key, () async {
      final html = await source.chapterDocument(index);
      if (html == null) throw StateError('无法读取听书位置对应的原书');
      try {
        final result = await parseLocatorDomMap(html, href, content, locator);
        while (_domMaps.length > 3) {
          _domMaps.remove(_domMaps.keys.first);
        }
        return result;
      } catch (_) {
        _domMaps.remove(key);
        rethrow;
      }
    });
  }

  Future<Map<String, Object>> resolvePosition(
    int index,
    String href,
    ChapterContent content,
    Locator locator,
  ) async => (await positionMap(index, href, content, locator)).displayPoint(locator);

  /// 章节按钮先保留当前画面，再执行定位；由正文区注册和释放。
  Future<void> Function(Future<void> Function() jump)? holdPageDuringJump;

  /// 加书签时读取当前页真实DOM落点，避免跨页段落的文字摘录退到上一页。
  Future<Locator> Function()? bookmarkAnchor;

  /// 宿主页的命令入口；[OriginalBody] 创建 WebView 后注入
  OriginalHostController? _host;

  void attachHost(OriginalHostController host) => _host = host;

  /// 界面把宿主页的原始消息转进来，拿到的是强类型事件
  OriginalHostEvent? handle(
    Map<String, Object?> raw, {
    required int chapterIndex,
  }) =>
      parseHostEvent(raw, chapterIndex: chapterIndex);

  /// 定位到章内比例（分栏完成后的落点、目录跳转）
  Future<void> goToFraction(double fraction) async {
    await _host?.goToFraction(fraction);
  }

  /// 跳到文档内的锚点（书内链接的 `#片段`）
  Future<void> goToAnchor(String id) async {
    await _host?.goToAnchor(id);
  }

  /// 点击：分区由界面算好，宿主页在同一次调用里判断「这一点是不是链接」
  Future<void> tap(double x, double y, String zone) async {
    await _host?.tap(x, y, zone);
  }

  /// 拖动中：页面跟手平移（无过渡）
  Future<void> drag(double dx) async {
    await _host?.drag(dx);
  }

  /// 松手：网页执行手势层已决定的上一页、当前页或下一页。
  Future<void> settle(int pageDelta) async {
    await _host?.settle(pageDelta);
  }

  /// 热更新字号与主题色（不重载文档）
  Future<void> applyStyle({
    double? fontSizePx,
    Map<String, String>? colors,
  }) async {
    await _host?.applyStyle(fontSizePx: fontSizePx, colors: colors);
  }

  void dispose() => source.close();
}

/// 原书排版模式的一次阅读会话（按书隔离）。
///
/// 打开 `source.epub` 并封好桥；打开失败（源文件缺失、与章节索引对不上）时这里抛错，
/// 由阅读页降级回简化排版并说明原因（计划 3.1）。
final originalLayoutProvider =
    FutureProvider.autoDispose.family<OriginalLayoutController, String>(
  (ref, bookId) async {
    // 只跟「书 + 章列表」走：会话状态每次翻页都会变，不能让它重建控制器
    // （重建会重新打开一次归档）
    final target = ref.watch(
      readerSessionProvider(bookId).select(
        (session) => (session.value?.book, session.value?.chapters),
      ),
    );
    final book = target.$1;
    final chapters = target.$2;
    if (book == null || chapters == null || chapters.isEmpty) {
      throw const ReaderFailure('正文还没准备好，稍后再试');
    }
    if (book.format != BookFormat.epub) {
      throw const ReaderFailure('只有 EPUB 能按原书样式排版');
    }
    final source = ref.watch(epubSourceRepositoryProvider).open(
          bookId: bookId,
          contentVersion: book.contentVersion,
          chapters: chapters,
        );
    final controller = OriginalLayoutController(bookId: bookId, source: source);
    ref.onDispose(controller.dispose);
    return controller;
  },
);
