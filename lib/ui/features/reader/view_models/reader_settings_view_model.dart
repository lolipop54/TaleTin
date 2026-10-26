/// 阅读设置（排版 + 主题）的界面状态（设计文档 2.3 / S10）。
///
/// 三级合并：内置默认 → 全局阅读默认值 → 本书覆盖。
/// - 面板里的每一次调整都写成**本书覆盖**的一项，其它项继续跟随全局；
/// - 「恢复全局」删除本书的全部覆盖，不把全局值抄成覆盖值；
/// - 全局默认值由 App 设置页维护。
///
/// 所有修改串行保存；成功后才发布新值，失败保留上次结果并提示。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  }) : fontSettings = settings;

  /// 合并后的排版参数（内置默认 → 全局 → 本书覆盖）
  final ReadingSettings fontSettings;
  final bool pdf;
  bool get pdfMode => pdf && fontSettings.layoutMode.isOriginal;

  /// 仅正文排版解析真实字体，保留“系统字体”选项用于显示与保存。
  ReadingSettings get settings => fontSettings.copyWith(
    fontFamily: ReadingFonts.resolve(fontSettings.fontFamily),
    bookEdges: !pdfMode && fontSettings.bookEdges,
    landscapeSpread: !pdfMode && fontSettings.landscapeSpread,
    pageTurnEffect: !pdfMode && fontSettings.spreadEnabled
        ? PageTurnEffect.curl
        : fontSettings.pageTurnEffect,
  );

  /// 合并后的阅读主题
  final ReadingTheme theme;

  /// 本书的窗口亮度覆盖 0–1；null 表示跟随系统（设计文档 2.3）
  final double? brightness;
  final double? customBrightness;

  bool get followSystemBrightness => brightness == null;

  /// 面板里的段落间距按像素显示
  double get paragraphGapPx => settings.paragraphGap;

  /// 面板里的字体三选
  ReadingFont get font => readingFontOf(fontSettings.fontFamily);

  /// 从全局偏好起底：本书覆盖还没读出来时先用它画主题，避免闪一下默认色
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

  /// 全局阅读默认值（构建时读入，之后只作合并用）
  ReadingSettings _global = kBuiltinReadingSettings;
  bool _pdf = false;
  final _backgroundTextures = <String, ReadingBackgroundTexture>{};
  String? _pendingBackgroundId;

  Future<ReadingTheme> _appearance(ReadingTheme theme, {String? id}) async {
    final repo = ref.read(readingBackgroundRepositoryProvider);
    final catalog = await ref.read(readingBackgroundsProvider.future);
    id ??= await repo.selection(bookId: bookId) ?? catalog.globalId;
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
    await ref
        .read(readingBackgroundRepositoryProvider)
        .select(id, bookId: bookId);
    if (ref.mounted) {
      state = AsyncData(
        ReaderSettingsState(
          pdf: _pdf,
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
          settings: current.fontSettings,
          theme: theme,
          brightness: current.brightness,
          customBrightness: current.customBrightness,
        ),
      );
    }
  });

  /// 本书的覆盖项：只放用户在这一本书里真正改过的项
  ReadingSettingsOverrides _overrides = const ReadingSettingsOverrides();

  @override
  Future<ReaderSettingsState> build() async {
    final repository = ref.watch(readingSettingsRepositoryProvider);
    ref.onDispose(() {
      for (final texture in _backgroundTextures.values) {
        texture.dispose();
      }
      _backgroundTextures.clear();
    });
    ref.listen(readingBackgroundsProvider, (previous, next) {
      if (previous?.hasValue == true && next.hasValue) _refreshBackground();
    });
    _global = await repository.loadGlobal() ?? kBuiltinReadingSettings;
    _overrides =
        await repository.loadOverrides(bookId) ??
        const ReadingSettingsOverrides();
    _pdf =
        (await ref.read(bookRepositoryProvider).findById(bookId))?.format ==
        BookFormat.pdf;
    // PDF首次进入原页模式；之后尊重本书保存的模式，不受其它格式的全局选择干扰。
    if (_overrides.layoutMode == null && _pdf) {
      _overrides = _overrides.copyWith(layoutMode: ReadingLayoutMode.original);
    }
    await _prepareFont(_global.mergeOver(_overrides));
    // 单书主题没设过时用全局主题
    final themeId =
        await repository.loadThemeId(bookId: bookId) ??
        await repository.loadThemeId();
    return ReaderSettingsState(
      pdf: _pdf,
      settings: _global.mergeOver(_overrides),
      theme: await _appearance(readingThemeOf(themeId)),
      brightness: await repository.loadBrightness(bookId),
      customBrightness: await repository.loadCustomBrightness(bookId),
    );
  }

  Future<void> _prepareFont(ReadingSettings settings) async {
    if (settings.layoutMode.isOriginal && settings.useOriginalFont) return;
    // 原书正文由 WebView 准备内置字体；在这里用 Flutter 再预排一次，
    // 会同步读取整份中文字体，既阻塞加载动画，也没有参与正文绘制。
    if (settings.layoutMode.isOriginal &&
        PresetFonts.families.containsKey(settings.fontFamily)) {
      return;
    }
    await ref.read(selectedFontLoaderProvider)(settings.fontFamily);
  }

  void setFontSize(int size) => _applyOverrides((o) {
    final next = _global.mergeOver(o).withFontSize(size);
    return o.copyWith(
      fontSize: next.fontSize,
      paragraphGapEm: next.paragraphGapEm,
    );
  });

  void setLineHeight(double value) => _applyOverrides(
    (o) => o.copyWith(
      // 面板按 0.1 步进，存进去也保持这个精度
      lineHeight: ((value * 10).round() / 10).clamp(
        ReadingLimits.minLineHeight,
        ReadingLimits.maxLineHeight,
      ),
    ),
  );

  /// 段落间距按像素调整，保存时换算为当前字号对应的 em。
  void setParagraphGap(double pixels) {
    final current = state.value;
    if (current == null) return;
    final fontSize = current.settings.fontSize;
    final em =
        (fontSize <= 0
                ? pixels / ReadingLimits.defaultFontSize
                : pixels / fontSize)
            .clamp(
              ReadingLimits.minParagraphGapEm,
              ReadingLimits.maxParagraphGapEm,
            );
    _applyOverrides((o) => o.copyWith(paragraphGapEm: em));
  }

  void setPagePadding(double value) => _applyOverrides(
    (o) => o.copyWith(
      horizontalPadding: value.clamp(
        ReadingLimits.minHorizontalPadding,
        ReadingLimits.maxHorizontalPadding,
      ),
    ),
  );

  void setBookEdges(bool value) =>
      _applyOverrides((o) => o.copyWith(bookEdges: value));
  void setLandscape(bool value) =>
      _applyOverrides((o) => o.copyWith(landscape: value));
  void setLandscapeSpread(bool value) =>
      _applyOverrides((o) => o.copyWith(landscapeSpread: value));

  void setIndent(bool value) =>
      _applyOverrides((o) => o.copyWith(indent: value));

  void setFontWeight(int value) =>
      _applyOverrides((o) => o.copyWith(fontWeight: value));

  void restoreOriginalFont() =>
      _applyOverrides((o) => o.copyWith(useOriginalFont: true));

  void setFontFamily(String family) => _applyOverrides(
    (o) => o.copyWith(fontFamily: family, useOriginalFont: false),
  );

  /// 弹层等待保存成功才关闭；失败由串行入口提示，仍保留候选和旧正文。
  Future<bool> confirmFontChoice(String id) async {
    await _applyOverrides(
      (o) => id == '__original'
          ? o.copyWith(useOriginalFont: true)
          : o.copyWith(fontFamily: id, useOriginalFont: false),
    );
    final current = state.value?.fontSettings;
    return current != null &&
        (id == '__original'
            ? current.useOriginalFont
            : !current.useOriginalFont && current.fontFamily == id);
  }

  void setFont(ReadingFont font) => _applyOverrides(
    (o) => o.copyWith(
      // 显式存系统字体，不能用 null（null 会继承全局宋体）。
      fontFamily: readingFontFamily(font) ?? 'sans-serif',
      useOriginalFont: false,
    ),
  );

  /// 排版模式（简化 / 原书）：本书覆盖，退出重进与换设备都跟着这本书走
  void setLayoutMode(ReadingLayoutMode mode) => _save(() async {
    final current = state.value;
    if (current == null) return;
    final next = _overrides.copyWith(layoutMode: mode);
    // 先保存用户这次选择；即使源书已改，重新导入后也按新排版打开。
    await ref
        .read(readingSettingsRepositoryProvider)
        .saveOverrides(bookId, next);
    if (!ref.mounted) return;
    _overrides = next;
    final book = await ref.read(bookRepositoryProvider).findById(bookId);
    if (!ref.mounted) return;
    if (book?.status == BookStatus.sourceChanged) {
      // 先阻止旧会话开始切换，后发布新选项；否则同步监听会先读取已改变的文件。
      ref.read(readerSourceChangeProvider(bookId).notifier).markChanged();
      state = AsyncData(
        ReaderSettingsState(
          pdf: _pdf,
          settings: _global.mergeOver(next),
          theme: current.theme,
          brightness: current.brightness,
          customBrightness: current.customBrightness,
        ),
      );
      return;
    }
    if (book?.format == BookFormat.pdf && mode.isOriginal) {
      // 原页模式没有听书入口；切入前暂停本书语音，并把位置保存权交给手动阅读。
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
    await _prepareFont(_global.mergeOver(next));
    if (ref.mounted) {
      state = AsyncData(
        ReaderSettingsState(
          pdf: _pdf,
          settings: _global.mergeOver(next),
          theme: current.theme,
          brightness: current.brightness,
          customBrightness: current.customBrightness,
        ),
      );
    }
  });

  void setPageTurnEffect(PageTurnEffect effect) =>
      _applyOverrides((o) => o.copyWith(pageTurnEffect: effect));

  void setAutoScrollSpeed(double speed) =>
      _applyOverrides((o) => o.copyWith(autoScrollSpeed: speed.clamp(12, 80)));
  void setAutoScanSeconds(int seconds) =>
      _applyOverrides((o) => o.copyWith(autoScanSeconds: seconds.clamp(2, 30)));
  void setAutoKeepAwake(bool enabled) =>
      _applyOverrides((o) => o.copyWith(autoKeepAwake: enabled));

  /// 阅读主题：不参与分页，单独一个键存
  Future<void> setTheme(ReadingTheme theme) => _save(() async {
    final current = state.value;
    if (current == null) return;
    await ref
        .read(readingSettingsRepositoryProvider)
        .saveThemeId(theme.name, bookId: bookId);
    if (!ref.mounted) return;
    state = AsyncData(
      ReaderSettingsState(
        pdf: _pdf,
        settings: current.fontSettings,
        theme: theme.withBackground(current.theme.texture),
        brightness: current.brightness,
        customBrightness: current.customBrightness,
      ),
    );
  });

  /// 窗口亮度：传 null 表示跟随系统（设计文档 2.3 的单书覆盖）
  Future<void> setBrightness(double? value) => _save(() async {
    final current = state.value;
    if (current == null) return;
    final clamped = value?.clamp(0.0, 1.0);
    await ref
        .read(readingSettingsRepositoryProvider)
        .saveBrightness(bookId, clamped);
    if (!ref.mounted) return;
    state = AsyncData(
      ReaderSettingsState(
        pdf: _pdf,
        settings: current.fontSettings,
        theme: current.theme,
        brightness: clamped,
        customBrightness:
            clamped ?? current.customBrightness ?? current.brightness,
      ),
    );
  });

  /// 恢复全局：删掉本书的全部覆盖（含主题），回到全局默认值
  Future<void> restoreGlobal() => _save(() async {
    final current = state.value;
    if (current == null) return;
    final repository = ref.read(readingSettingsRepositoryProvider);
    final global = await repository.loadGlobal() ?? kBuiltinReadingSettings;
    await _prepareFont(global);
    final theme = await _appearance(
      readingThemeOf(await repository.loadThemeId()),
      id: (await ref.read(readingBackgroundsProvider.future)).globalId,
    );
    // 仓库一次删除排版、主题和亮度覆盖，保留本书想法草稿。
    await repository.clearOverrides(bookId);
    if (!ref.mounted) return;
    _global = global;
    _overrides = const ReadingSettingsOverrides();
    state = AsyncData(
      ReaderSettingsState(pdf: _pdf, settings: _global, theme: theme),
    );
  });

  /// 只保存本次改动的字段，其余继续继承；连续拖动按顺序提交。
  Future<void> _applyOverrides(
    ReadingSettingsOverrides Function(ReadingSettingsOverrides) change,
  ) {
    return _save(() async {
      final current = state.value;
      if (current == null) return;
      final next = change(_overrides);
      await _prepareFont(_global.mergeOver(next));
      await ref
          .read(readingSettingsRepositoryProvider)
          .saveOverrides(bookId, next);
      if (!ref.mounted) return;
      _overrides = next;
      state = AsyncData(
        ReaderSettingsState(
          pdf: _pdf,
          settings: _global.mergeOver(_overrides),
          theme: current.theme,
          brightness: current.brightness,
          customBrightness: current.customBrightness,
        ),
      );
    });
  }
}

/// 按书隔离：每本书有自己的覆盖项，退出阅读页即释放（设计文档 4.2）。
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
