import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/models/automatic_scan.dart';
import '../view_models/automatic_reading.dart';
import 'scan_frames.dart';
import 'scan_frames_painter.dart';

/// 扫描显示器不另存阅读位置，整轮结束只调用阅读会话的提交入口。
class AutomaticScanArea extends ConsumerStatefulWidget {
  const AutomaticScanArea({super.key, required this.bookId, required this.page,
    required this.ready, required this.prepare, required this.bounds,
    required this.paper, required this.line, required this.child, this.frameBounds});
  final String bookId;
  final ScanPage page;
  final bool Function() ready;
  final Future<ScanPreparation> Function(ValueChanged<ui.Image> cover) prepare;
  final Rect bounds;
  final Rect? frameBounds;
  final Color paper, line;
  final Widget child;
  @override
  ConsumerState<AutomaticScanArea> createState() => AutomaticScanAreaState();
}

class AutomaticScanAreaState extends ConsumerState<AutomaticScanArea>
    with SingleTickerProviderStateMixin {
  late final AutomaticReadingNotifier _automatic;
  late final AutomaticScrollBackend _backend;
  late final Ticker _ticker;
  AutomaticScan? _scan;
  ScanPreparation? _prepared;
  ui.Image? _cover;
  Future<void>? _flight;
  bool _running = false, _committing = false;
  int _version = 0;
  double _seconds = 8;
  double get progress => _scan?.progress ?? 0;
  ScanPhase? get phase => _scan?.phase;
  ScanFrames? get frames => _prepared?.frames;

  @override
  void initState() {
    super.initState();
    _automatic = ref.read(automaticReadingProvider(widget.bookId).notifier);
    _ticker = createTicker(_tick);
    _backend = AutomaticScrollBackend(ready: () => widget.ready(), start: _start,
      stop: _stop, speed: (seconds) => _seconds = seconds,
      discard: _discard, retained: () => _prepared != null && progress < 1);
    _automatic.attach(_backend);
  }

  Future<void> _start(double seconds) async {
    await _flight;
    _seconds = seconds; _running = true;
    if (_prepared != null && _scan?.current == widget.page && progress < 1) {
      _scan!.resume(); _ticker.start(); return;
    }
    setState(_release);
    try {
      await (_flight = _prepare().whenComplete(() => _flight = null));
    } catch (_) {
      _scan?.fail(); _running = false;
      if (mounted) setState(_release);
      rethrow;
    }
  }

  Future<void> _prepare() async {
    _automatic.reportAdvancing(false);
    final version = ++_version;
    final scan = _scan = AutomaticScan(widget.page);
    final task = scan.prepare();
    final prepared = await widget.prepare((image) {
      if (!mounted || version != _version) return;
      setState(() { _cover?.dispose(); _cover = image.clone(); });
    });
    if (!mounted || version != _version) { prepared.frames.dispose(); return; }
    setState(() {
      _prepared = prepared; _cover?.dispose(); _cover = null;
      scan.prepared(task, prepared.commit == null ? null : (bookId: widget.page.bookId,
        contentVersion: widget.page.contentVersion, layout: widget.page.layout,
        page: prepared.targetPage!));
      if (!_running) scan.pause();
    });
    if (_running) _ticker.start();
  }

  void _tick(Duration elapsed) {
    final scan = _scan;
    final before = scan?.progress;
    final complete = scan?.advance(elapsed, _seconds) ?? false;
    _automatic.reportAdvancing(!complete && scan != null && scan.progress != before);
    if (!complete) {
      if (mounted) setState(() {});
      return;
    }
    _ticker.stop(); _committing = true;
    setState(() {});
    _flight = _complete().catchError((Object error) {
      if (!mounted) return;
      _scan?.fail(); _running = false;
      setState(_release);
      _automatic.finish('自动阅读暂停：$error');
    }).whenComplete(() { _committing = false; _flight = null; });
  }

  Future<void> _complete() async {
    // 先把完整目标帧画出来，再提交位置；不会播放普通翻页动画。
    await WidgetsBinding.instance.endOfFrame;
    final prepared = _prepared!;
    if (prepared.commit == null) {
      _scan!.complete(); _running = false;
      _automatic.finish('已到全书末尾'); return;
    }
    await prepared.commit!();
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    setState(_release);
    _scan?.complete();
    if (_running) await _prepare();
  }

  Future<void> _stop() async {
    _running = false; _ticker.stop(); _scan?.pause();
    await _flight;
  }

  Future<void> _discard() async {
    ++_version; // 先作废准备结果，再等待临时预览恢复，旧任务不能重新盖住新布局。
    await _stop(); _scan?.invalidate();
    if (mounted) setState(_release);
  }

  void _release() {
    final old = _prepared, cover = _cover;
    _prepared = null; _cover = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old?.frames.dispose(); cover?.dispose();
    });
  }

  @override
  void didUpdateWidget(AutomaticScanArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.layout != widget.page.layout ||
        (!_committing && oldWidget.page != widget.page)) {
      final active = _running;
      _running = false; _ticker.stop(); final version = ++_version; _scan?.invalidate();
      _release();
      if (active) scheduleMicrotask(() { if (mounted && version == _version) _automatic.pause(); });
    }
  }

  @override
  void dispose() {
    ++_version; _running = false; _ticker.dispose();
    _automatic.detach(_backend); _release(); super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
    widget.child,
    if (_cover != null && widget.frameBounds != null) Positioned.fromRect(rect: widget.frameBounds!,
      child: IgnorePointer(child: RawImage(image: _cover, fit: BoxFit.fill))),
    if (_cover != null && widget.frameBounds == null) Positioned.fill(
      child: IgnorePointer(child: RawImage(image: _cover, fit: BoxFit.fill))),
    if (_prepared != null) IgnorePointer(child: RepaintBoundary(child: CustomPaint(
      key: const Key('automatic-scan-paint'), painter: ScanFramesPainter(
        frames: _prepared!.frames, progress: progress, bounds: widget.bounds,
        frameBounds: widget.frameBounds,
        paper: widget.paper, line: widget.line)))),
  ]);
}
