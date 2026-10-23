import 'dart:ui' as ui;

import '../../../../core/diagnostics/reader_work_trace.dart';
import 'prepared_page.dart';
import 'turn_trace.dart';

/// 空闲时完成原尺寸页图栅格化；最多两张、合计24MiB，不降低分辨率。
/// 动态选区／标注／听书及菜单沿用实时画法，不缓存这些易变外观。
class PageRasterCache {
  PageRasterCache({this.budgetBytes = 24 * 1024 * 1024});
  final int budgetBytes;
  final _entries = <Object, _RasterPage>{};
  Future<void>? _pending;
  int _generation = 0;
  bool _disposed = false;

  int get length => _entries.length;
  int get bytes => _entries.values.fold(0, (n, page) => n + page.bytes);

  Object? _key(PreparedPage prepared, ui.Size size, double ratio) {
    final page = prepared.page;
    if (page.selectionRects.isNotEmpty ||
        page.selectionHandles.isNotEmpty ||
        page.speechRects.isNotEmpty ||
        page.highlights.isNotEmpty ||
        page.thoughtMarkers.isNotEmpty ||
        page.information?.searchMenu != null) {
      return null;
    }
    return (
      page.layout.identity,
      page.pageIndex,
      page.theme,
      size,
      ratio,
      page.information?.paintingKey,
    );
  }

  /// 返回独立图像句柄，手势结束只释放该引用，缓存本身仍可供来回翻页。
  ui.Image? find(PreparedPage page, ui.Size size, double ratio) {
    final key = _key(page, size, ratio);
    final entry = _entries.remove(key);
    final hit = entry != null && entry.page.sameImagesAs(page);
    readerPerf('simplified.raster.cache', 0, {
      'hit': hit,
      'entries': length + (entry == null ? 0 : 1),
      'bytes': bytes + (entry?.bytes ?? 0),
    });
    if (entry == null) return null;
    if (!hit) {
      entry.dispose();
      return null;
    }
    _entries[key!] = entry;
    return entry.image.clone();
  }

  Future<void> prepare(PreparedPage page, ui.Size size, double ratio) {
    if (_disposed) return Future.value();
    // 同时最多一个离屏栅格任务，旧窗口的在途任务也要先结束再接新任务。
    if (_pending case final pending?) {
      return pending.then((_) => prepare(page, size, ratio));
    }
    final key = _key(page, size, ratio);
    final width = (size.width * ratio).ceil(),
        height = (size.height * ratio).ceil();
    if (key == null ||
        width <= 0 ||
        height <= 0 ||
        width * height * 4 > budgetBytes) {
      return Future.value();
    }
    final existing = _entries.remove(key);
    if (existing != null && existing.page.sameImagesAs(page)) {
      // 邻页刚变成当前页时也要刷新顺序，否则准备下一张会淘汰当前页。
      _entries[key] = existing;
      return Future.value();
    }
    existing?.dispose();
    _pending = _prepare(
      page,
      key,
      size,
      ratio,
      width,
      height,
    ).whenComplete(() => _pending = null);
    return _pending!;
  }

  Future<void> _prepare(
    PreparedPage page,
    Object key,
    ui.Size size,
    double ratio,
    int width,
    int height,
  ) async {
    final generation = _generation, snapshot = page.clone();
    final recorder = ui.PictureRecorder();
    snapshot.paint(ui.Canvas(recorder)..scale(ratio), size);
    final picture = recorder.endRecording();
    final trace = ReaderWorkTrace.start('page.raster_image', {
      'width': width,
      'height': height,
      'bytes': width * height * 4,
    });
    ui.Image? image;
    try {
      // 等离屏栅格完成才发布命中，不能把toImageSync返回句柄当成GPU已完成。
      image = await picture.toImage(width, height);
      if (_disposed || generation != _generation) return;
      _entries.remove(key)?.dispose();
      _entries[key] = _RasterPage(snapshot.clone(), image);
      image = null;
      while (_entries.length > 2 || bytes > budgetBytes) {
        _entries.remove(_entries.keys.first)!.dispose();
      }
      trace?.finish();
    } catch (_) {
      // 离屏缓存失败时保留原来的按需生成流程，不影响正文及本次翻页。
      trace?.finish(status: 'failed');
    } finally {
      trace?.finish(status: 'cancelled');
      image?.dispose();
      picture.dispose();
      snapshot.dispose();
    }
  }

  void clear() {
    _generation++;
    for (final page in _entries.values) {
      page.dispose();
    }
    _entries.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}

class _RasterPage {
  _RasterPage(this.page, this.image);
  final PreparedPage page;
  final ui.Image image;
  int get bytes => image.width * image.height * 4;
  void dispose() {
    image.dispose();
    page.dispose();
  }
}
