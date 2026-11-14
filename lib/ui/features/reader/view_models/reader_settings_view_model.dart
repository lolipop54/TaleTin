/// 阅读器按书管理画面资源，阅读偏好统一读写全局设置。
/// 修改串行保存，字体和背景准备好后才发布，旧单书覆盖不再参与读取。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/view_models/global_reading_settings.dart';

import '../../../core/theme/reading_background_texture.dart';
import '../../settings/view_models/reading_backgrounds.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../../platform/channels/reading_fonts.dart';
import '../../../../platform/channels/preset_fonts.dart';
import '../../../core/theme/reading_theme.dart';
import 'reader_settings_mapper.dart';
import 'reader_view_model.dart';
import '../../../../domain/models/book.dart';
import 'reader_source_change.dart';
import 'reader_session_view_model.dart';

/// 一本书当前生效的阅读设置
class ReaderSettingsState {
  const ReaderSettingsState({
    required ReadingSettings settings,
    required this.theme,
    this.brightness,
    this.customBrightness,
    this.pdf = false,
    this.supportsBookFonts = false,
  }) : fontSettings = settings;

  /// 全局排版参数；显示时按格式限制不支持的功能。
  final ReadingSettings fontSettings;
  final bool pdf;
  final bool supportsBookFonts;
  ReadingLayoutMode get layoutMode => fontSettings.layoutModeFor(pdf: pdf);
  bool get pdfMode => pdf && layoutMode.isOriginal;
  bool freePdfView({required bool fixedView}) => pdfMode && !fixedView;

  PageTurnEffect pageTurnFor({required bool fixedView}) =>
      freePdfView(fixedView: fixedView)
      ? settings.pageTurnEffect.forPdfFreeView()
      : settings.pageTurnEffect;
  bool get _bookFonts =>
      supportsBookFonts &&
      !layoutMode.isOriginal &&
      fontSettings.useBookFontsInSimplified;

  /// 仅正文排版解析真实字体，保留“系统字体”选项用于显示与保存。
  ReadingSettings get settings => fontSettings.copyWith(
    layoutMode: layoutMode,
    useBookFontsInSimplified: _bookFonts,
    fontFamily: ReadingFonts.resolve(
      _bookFonts ? 'sans-serif' : fontSettings.fontFamily,
    ),
    bookEdges: !pdfMode && fontSettings.bookEdges,
    landscapeSpread: !pdfMode && fontSettings.landscapeSpread,
    pageTurnEffect: !pdfMode && fontSettings.spreadEnabled
        ? PageTurnEffect.curl
        : fontSettings.pageTurnEffect,
  );

  /// 合并后的阅读主题
  final ReadingTheme theme;

  /// 全局窗口亮度 0–1；null 表示跟随系统。
  final double? brightness;
  final double? customBrightness;

  bool get followSystemBrightness => brightness == null;

  /// 面板里的段落间距按像素显示
  double get paragraphGapPx => settings.paragraphGap;

  /// 面板里的字体三选
  ReadingFont get font => readingFontOf(fontSettings.fontFamily);

  /// 阅读资源未就绪时沿用全局主题，避免闪一下默认色。
  factory ReaderSettingsState.fromGlobal(GlobalReadingPreferences global) =>
      ReaderSettingsState(
        settings: global.typography,
        theme: readingThemeOf(global.themeId),
      );
}

class ReaderSettingsNotifier extends AsyncNotifier<ReaderSettingsState> {
  ReaderSettingsNotifier(this.bookId);

  final String bookId;
  Future<void> _writing = Future.value();

  /// 离开前或检查时可以等待已提交的设置操作。
  Future<void> get pendingWrites => _writing;

  Future<void> _save(Future<void> Function() action) {
    final operation = _writing.then((_) => action());
    _writing = operation.catchError((Object error) {
      if (ref.mounted) {
        ref.read(readerProvider.notifier).showNotice('设置未保存，请重试');
      }
    });
    return _writing;
  }

  bool _pdf = false;
  bool _supportsBookFonts = false;
  final _backgroundTextures = <String, ReadingBackgroundTexture>{};
  String? _pendingBackgroundId;

  Future<ReadingTheme> _appearance(ReadingTheme theme, {String? id}) async {
    final catalog = await ref.read(readingBackgroundsProvider.future);
    id ??= catalog.globalId;
    final choice = catalog.find(id);
    _pendingBackgroundId = choice.id;
    if (choice.id == 'solid') return theme.base;
    final texture = _backgroundTextures[choice.id] ??=
        await ReadingBackgroundTexture.load(
          choice,
          ref.read(libraryRootPathProvider),
        );
    if (!ref.mounted) {
      _backgroundTextures.remove(choice.id)?.dispose();
      throw StateError('阅读页已关闭');
    }
    return theme.withBackground(texture);
  }

  /// 新画面交接完成后再释放旧背景，旧页面与截图准备阶段仍能安全绘制。
  void releaseUnusedBackgrounds() {
    final current = state.value?.theme.texture;
    _backgroundTextures.removeWhere((_, texture) {
      if (identical(texture, current) || texture.id == _pendingBackgroundId) {
        return false;
      }
      texture.dispose();
      return true;
    });
  }

  Future<void> setBackground(String id) => _save(() async {
    final current = state.value;
    if (current == null) return;
    final theme = await _appearance(current.theme, id: id);
    await ref.read(readingBackgroundsProvider.notifier).selectGlobal(id);
    if (ref.mounted) {
      state = AsyncData(
        ReaderSettingsState(
          pdf: _pdf,
          supportsBookFonts: _supportsBookFonts,
          settings: current.fontSettings,
          theme: theme,
          brightness: current.brightness,
          customBrightness: current.customBrightness,
        ),
      );
    }
  });

  Future<void> _refreshBackground() => _save(() async {
    final current = state.value;
    if (current == null) return;
    final theme = await _appearance(current.theme);
    if (ref.mounted && theme != current.theme) {
      state = AsyncData(
        ReaderSettingsState(
          pdf: _pdf,
          supportsBookFonts: _supportsBookFonts,
          settings: current.fontSettings,
          theme: theme,
          brightness: current.brightness,
          customBrightness: current.customBrightness,
        ),
      );
    }
  });

  @override
  Future<ReaderSettingsState> build() async {
    ref.watch(readingSettingsRepositoryProvider);
    ref.onDispose(() {
      for (final texture in _backgroundTextures.values) {
        texture.dispose();
      }
      _backgroundTextures.clear();
    });
    ref.listen(readingBackgroundsProvider, (previous, next) {
      if (previous?.hasValue == true && next.hasValue) _refreshBackground();
    });
    // 不重建notifier：保留旧纸面和纹理，目标准备好后才更新。
    ref.listen(globalSettingsProvider, (previous, next) {
      if (previous?.hasValue == true &&
          next.hasValue &&
          previous?.value != next.value) {
        _save(_refreshGlobal);
      }
    });
    ref.listen(globalBrightnessProvider, (previous, next) {
      if (previous?.hasValue == true && next.hasValue) {
        _save(_refreshBrightness);
      }
    });
    final brightness = await ref.read(globalBrightnessProvider.future);
    final global = await ref.read(globalSettingsProvider.future);
    final format = (await ref.read(bookRepositoryProvider).findById(bookId))
        ?.format;
    _pdf = format == BookFormat.pdf;
    _supportsBookFonts = format?.usesOriginalWebView == true;
    await _prepareFont(global.typography);
    return ReaderSettingsState(
      pdf: _pdf,
      supportsBookFonts: _supportsBookFonts,
      settings: global.typography,
      theme: await _appearance(readingThemeOf(global.themeId)),
      brightness: brightness.value,
      customBrightness: brightness.custom,
    );
  }

  Future<void> _refreshGlobal({bool prepare = true}) async {
    final current = state.value;
    if (current == null) return;
    final global = ref.read(globalSettingsProvider).requireValue;
    if (current.fontSettings == global.typography &&
        current.theme.name == readingThemeOf(global.themeId).name) {
      return;
    }
    if (prepare) await _prepareSettings(global.typography);
    final theme = await _appearance(readingThemeOf(global.themeId));
    if (!ref.mounted) return;
    state = AsyncData(
      ReaderSettingsState(
        pdf: _pdf,
        supportsBookFonts: _supportsBookFonts,
        settings: global.typography,
        theme: theme,
        brightness: current.brightness,
        customBrightness: current.customBrightness,
      ),
    );
  }

  /// PDF切回原页前交接听书位置；源书已变更时不能再读取旧正文。
  Future<void> _prepareSettings(ReadingSettings next) async {
    final current = state.value;
    final mode = next.layoutModeFor(pdf: _pdf);
    if (current?.layoutMode != mode) {
      final book = await ref.read(bookRepositoryProvider).findById(bookId);
      if (!ref.mounted) return;
      if (book?.status == BookStatus.sourceChanged) {
        ref.read(readerSourceChangeProvider(bookId).notifier).markChanged();
        return;
      }
      if (_pdf && mode.isOriginal) {
        final service = ref.read(listeningServiceProvider);
        if (service.snapshot.bookId == bookId &&
            service.snapshot.desiredPlaying) {
          await service.pause();
        }
        await ref
            .read(readerSessionProvider(bookId).notifier)
            .beginManualReading();
        if (!ref.mounted) return;
      }
    }
    await _prepareFont(next);
  }

  Future<void> _prepareFont(ReadingSettings settings) async {
    final original = settings.layoutModeFor(pdf: _pdf).isOriginal;
    if (original && settings.useOriginalFont) return;
    // 原书正文由 WebView 准备内置字体；在这里用 Flutter 再预排一次，
    // 会同步读取整份中文字体，既阻塞加载动画，也没有参与正文绘制。
    if (original && PresetFonts.families.containsKey(settings.fontFamily)) {
      return;
    }
    await ref.read(selectedFontLoaderProvider)(
      !original && _supportsBookFonts && settings.useBookFontsInSimplified
          ? 'sans-serif'
          : settings.fontFamily,
    );
  }

  void setFontSize(int size) => _applySettings((s) => s.withFontSize(size));

  void setLineHeight(double value) => _applySettings(
    (o) => o.copyWith(
      // 面板按 0.1 步进，存进去也保持这个精度
      lineHeight: ((value * 10).round() / 10).clamp(
        ReadingLimits.minLineHeight,
        ReadingLimits.maxLineHeight,
      ),
    ),
  );

  /// 段落间距按像素调整，保存时换算为当前字号对应的 em。
  void setParagraphGap(double pixels) =>
      _applySettings((s) => s.copyWith(paragraphGapEm: pixels / s.fontSize));

  void setPagePadding(double value) => _applySettings(
    (o) => o.copyWith(
      horizontalPadding: value.clamp(
        ReadingLimits.minHorizontalPadding,
        ReadingLimits.maxHorizontalPadding,
      ),
    ),
  );

  void setBookEdges(bool value) =>
      _applySettings((o) => o.copyWith(bookEdges: value));
  void setLandscape(bool value) =>
      _applySettings((o) => o.copyWith(landscape: value));
  void setLandscapeSpread(bool value) =>
      _applySettings((o) => o.copyWith(landscapeSpread: value));

  void setIndent(bool value) =>
      _applySettings((o) => o.copyWith(indent: value));

  void setFontWeight(int value) =>
      _applySettings((o) => o.copyWith(fontWeight: value));

  void restoreOriginalFont() => _applySettings(
    (o) => o.withFontChoice('__original', o.layoutModeFor(pdf: _pdf)),
  );

  void setFontFamily(String family) => _applySettings(
    (o) => o.withFontChoice(family, o.layoutModeFor(pdf: _pdf)),
  );

  /// 弹层等待保存成功才关闭；失败由串行入口提示，仍保留候选和旧正文。
  Future<bool> confirmFontChoice(String id) async {
    await _applySettings(
      (o) => o.withFontChoice(id, o.layoutModeFor(pdf: _pdf)),
    );
    final current = state.value?.fontSettings;
    return current != null &&
        (id == '__original'
            ? current.usesBookFont(current.layoutModeFor(pdf: _pdf))
            : !current.useOriginalFont &&
                  !current.useBookFontsInSimplified &&
                  current.fontFamily == id);
  }

  void setFont(ReadingFont font) => _applySettings(
    (o) => o.withFontChoice(
      // 显式存系统字体，不能用 null（null 会继承全局宋体）。
      readingFontFamily(font) ?? 'sans-serif',
      o.layoutModeFor(pdf: _pdf),
    ),
  );

  /// 所有 PDF 共用一项模式，其他格式沿用各自的排版规则。
  void setLayoutMode(ReadingLayoutMode mode) => _applySettings(
    (s) =>
        _pdf ? s.copyWith(pdfLayoutMode: mode) : s.copyWith(layoutMode: mode),
  );

  void setPageTurnEffect(PageTurnEffect effect) =>
      _applySettings((o) => o.copyWith(pageTurnEffect: effect));

  void setAutoScrollSpeed(double speed) =>
      _applySettings((o) => o.copyWith(autoScrollSpeed: speed.clamp(12, 80)));
  void setAutoScanSeconds(int seconds) =>
      _applySettings((o) => o.copyWith(autoScanSeconds: seconds.clamp(2, 30)));

  /// 阅读主题：不参与分页，单独一个键存
  Future<void> setTheme(ReadingTheme theme) => _save(() async {
    final current = state.value;
    if (current == null) return;
    await ref.read(globalSettingsProvider.notifier).theme(theme.name);
    if (!ref.mounted) return;
    state = AsyncData(
      ReaderSettingsState(
        pdf: _pdf,
        supportsBookFonts: _supportsBookFonts,
        settings: current.fontSettings,
        theme: theme.withBackground(current.theme.texture),
        brightness: current.brightness,
        customBrightness: current.customBrightness,
      ),
    );
  });

  /// 全局窗口亮度：null表示跟随系统，保留上次自定义值。
  Future<void> setBrightness(double? value) => _save(() async {
    await ref
        .read(globalBrightnessProvider.notifier)
        .set(value?.clamp(0.0, 1.0));
    await _refreshBrightness();
  });

  Future<void> _refreshBrightness() async {
    final current = state.value;
    if (current == null) return;
    final brightness = ref.read(globalBrightnessProvider).requireValue;
    if (ref.mounted) {
      state = AsyncData(
        ReaderSettingsState(
          pdf: _pdf,
          supportsBookFonts: _supportsBookFonts,
          settings: current.fontSettings,
          theme: current.theme,
          brightness: brightness.value,
          customBrightness: brightness.custom,
        ),
      );
    }
  }

  /// 兼容旧调用；阅读已经只使用全局偏好，不删除书籍资料。
  Future<void> restoreGlobal() => _save(_refreshGlobal);

  /// 两处入口共用全局写入队列，从最新值修改本次字段。
  Future<void> _applySettings(
    ReadingSettings Function(ReadingSettings) change,
  ) => _save(() async {
    await ref
        .read(globalSettingsProvider.notifier)
        .change(change, prepare: _prepareSettings);
    await _refreshGlobal(prepare: false);
  });
}

/// 按书管理画面资源，设置值共用全局，退出阅读释放资源。
final readerSettingsProvider =
    AsyncNotifierProvider.family<
      ReaderSettingsNotifier,
      ReaderSettingsState,
      String
    >(ReaderSettingsNotifier.new, isAutoDispose: true);

/// 窗口亮度的拖动预览与磁盘设置分开，拖动过程中不反复写库。
class BrightnessPreview extends Notifier<double?> {
  @override
  double? build() => null;
  void set(double? value) => state = value;
}

final brightnessPreviewProvider = NotifierProvider.autoDispose
    .family<BrightnessPreview, double?, String>((_) => BrightnessPreview());
