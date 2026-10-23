import 'package:taletin/core/diagnostics/app_errors.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/services/backup_snapshot.dart';
import '../domain/repositories/app_theme_repository.dart';
import '../ui/features/import/view_models/import_view_model.dart';
import '../ui/features/settings/view_models/global_reading_settings.dart';
import 'app.dart';
import 'app_error_hooks.dart';
import 'bootstrap.dart';
import 'di/app_providers.dart';
import 'di/app_font_providers.dart';
import 'di/theme_providers.dart';
import 'restore_runtime.dart';
import 'restore_status_overlay.dart';
import 'runtime_scope.dart';

/// 旧页面卸载期间保留其截图，等新容器和书架数据就绪才撤掉遮盖。
class RestorableApp extends StatefulWidget {
  const RestorableApp({super.key, required this.initial});
  final BootstrapResult initial;
  @override
  State<RestorableApp> createState() => _RestorableAppState();
}

class _RestorableAppState extends State<RestorableApp> {
  final _paint = GlobalKey();
  late BootstrapResult _runtime = widget.initial;
  late ProviderContainer? _container = _makeContainer(_runtime);
  ProviderContainer? _candidate;
  final _warmSubscriptions = <void Function()>[];
  ui.Image? _picture;
  bool _busy = false, _visible = true;
  String? _message, _fatal;
  AppThemeMode _overlayTheme = AppThemeMode.system;
  String? _overlayFontFamily;
  late final AppLifecycleListener _lifecycle;

  ProviderContainer _makeContainer(BootstrapResult result) => ProviderContainer(observers: const [AppErrorObserver()], overrides: [
    ...runtimeOverrides(result), restoreLibraryProvider.overrideWithValue(_restore),
  ]);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onInactive: () {
      if (!_busy) unawaited(_runtime.listeningHandler.flushPosition());
    });
  }

  Future<void> _prepare(BootstrapResult next) async {
    _releaseWarmSubscriptions();
    _candidate?.dispose();
    final container = _candidate = _makeContainer(next);
    // Riverpod 3 会暂停没有监听者的数据流；预热时页面尚未挂载，需显式监听。
    _warmSubscriptions.add(container.listen(libraryBooksProvider, (_, _) {}).close);
    _warmSubscriptions.add(container.listen(fontFamilyNamesProvider, (_, _) {}).close);
    _warmSubscriptions.add(container.listen(appFontFamilyProvider, (_, _) {}).close);
    await container.read(libraryBooksProvider.future);
    await container.read(fontFamilyNamesProvider.future);
    await container.read(appFontFamilyProvider.future);
  }

  void _releaseWarmSubscriptions() {
    for (final close in _warmSubscriptions) { close(); }
    _warmSubscriptions.clear();
  }

  Future<void> _restore(BackupSnapshot incoming) async {
    if (_busy) return;
    // 旧容器会在恢复中释放，先保留主题，避免切换时退回默认紫色。
    _overlayTheme = _container!.read(appThemeProvider);
    _overlayFontFamily = _container!.read(appFontFamilyProvider).value;
    setState(() { _busy = true; _message = '等待当前任务结束'; });
    final old = _container!;
    final releaseSearch = <void Function()>[];
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary = _paint.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      _picture = await boundary.toImage(pixelRatio: View.of(context).devicePixelRatio);
      setState(() {});
      await old.read(importProvider.notifier).waitForIdle();
      await old.read(globalSettingsProvider.notifier).flush();
      final search = old.read(bookSearchRepositoryProvider);
      for (final book in await old.read(libraryBooksProvider.future)) {
        releaseSearch.add(await search.prepareContentChange(book.id));
      }
      final result = await restoreRuntime(_runtime, incoming,
        availableBytes: old.read(documentPlatformProvider).availableBytes,
        progress: (message) { if (mounted) setState(() => _message = message); },
        releaseUi: () async {
          setState(() => _visible = false);
          await WidgetsBinding.instance.endOfFrame;
          old.dispose(); _container = null;
        }, prepareUi: _prepare);
      _runtime = result.runtime;
      _overlayTheme = _candidate!.read(appThemeProvider);
      _overlayFontFamily = _candidate!.read(appFontFamilyProvider).value;
      setState(() { _container = _candidate; _candidate = null; _visible = true; _message = result.message; });
      // 等新书架真正绘制一帧后，才撤去原画面。
      await WidgetsBinding.instance.endOfFrame;
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '恢复书库失败');
      if (_container == null) {
        _candidate?.dispose(); _candidate = null;
        _fatal = '恢复未能完成，数据与恢复记录已保留。请重新打开应用重试：$error';
      }
      _message = '恢复失败，当前数据未替换：$error';
    } finally {
      _releaseWarmSubscriptions();
      for (final release in releaseSearch) { release(); }
      _picture?.dispose(); _picture = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _releaseWarmSubscriptions();
    _lifecycle.dispose(); _container?.dispose(); _candidate?.dispose(); _picture?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(textDirection: TextDirection.ltr,
    child: Stack(fit: StackFit.expand, children: [
      if (_visible && _container != null) RepaintBoundary(key: _paint,
        child: UncontrolledProviderScope(container: _container!,
          child: AbsorbPointer(absorbing: _busy,
            child: GTReaderApp(key: ObjectKey(_runtime), listening: _runtime.listeningHandler.service)))),
      if (_picture != null) RawImage(image: _picture, fit: BoxFit.fill),
      if (_busy || _message != null || _fatal != null) Positioned.fill(
        child: RestoreStatusOverlay(mode: _overlayTheme, busy: _busy,
          fontFamily: _overlayFontFamily,
          fatal: _fatal != null, message: _fatal ?? _message ?? '',
          onDismiss: () => setState(() => _message = null))),
    ]));
}
