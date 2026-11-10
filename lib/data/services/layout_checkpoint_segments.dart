part of 'file_layout_checkpoint_store.dart';

/// 只把新增的约64行测量资料送到后台。旧分段留在磁盘，不再随整章前缀复制。
Future<void> _writeCheckpointSegments(
  String path,
  Map<String, Object?> latest, {
  required bool repair,
  required int budget,
}) async {
  final previous = repair ? null : await _checkpointManifest(path);
  final blocks = latest['blocks'] as List;
  final base = latest['_from'] as int? ?? 0;
  final end = base + blocks.length;
  final parts = [
    for (final part in previous?['parts'] as List? ?? const [])
      Map<String, dynamic>.from(part as Map),
  ];
  final oldMetadata = previous?['metadata'] as Map?;
  final oldStart = parts.isEmpty ? 0 : parts.first['from'] as int;
  final oldEnd = parts.isEmpty
      ? 0
      : (parts.last['from'] as int) + (parts.last['count'] as int);
  final newPoints = latest['pageRestarts'] as List? ?? const [];
  final oldPoints = oldMetadata?['pageRestarts'] as List? ?? const [];
  final newestPage = newPoints.isEmpty ? 0 : newPoints.last[0] as int;
  final savedPage = oldPoints.isEmpty ? 0 : oldPoints.last[0] as int;
  if (oldMetadata != null &&
      base >= oldStart &&
      end <= oldEnd &&
      ((oldMetadata['cursor'] as int) > (latest['cursor'] as int) ||
          (oldMetadata['cursor'] == latest['cursor'] &&
              newestPage <= savedPage))) {
    return; // 已覆盖的短请求不缩短现有缓存。
  }

  var from = base;
  if (parts.isNotEmpty && base <= oldEnd && end >= oldEnd) {
    // 末段可能未满64行，重新封装这一小段即可。已恢复的窗口若从末段中间
    // 开始，则保留末段，直接从其末尾追加，不能丢掉窗口之前的有效行。
    final tail = parts.last['from'] as int;
    if (base <= tail) {
      from = tail;
      parts.removeLast();
    } else {
      from = oldEnd;
    }
  } else {
    parts.clear(); // 不相接的新阅读区间替换旧区间，绝不拼接出缺行的缓存。
  }
  final points = <int, List<int>>{
    if (parts.isNotEmpty)
      for (final point in oldPoints)
        (point as List)[0] as int: point.cast<int>(),
    for (final point in newPoints) (point as List)[0] as int: point.cast<int>(),
  }.values.toList()..sort((a, b) => a[0].compareTo(b[0]));
  final metadata = Map<String, Object?>.of(latest)
    ..remove('blocks')
    ..remove('_from')
    ..remove('pageRestarts');
  var total = parts.fold<int>(0, (n, part) => n + (part['bytes'] as int));
  do {
    var next = (from + 64).clamp(base, end);
    // 表格一次整体测量，只有整组末行带正文游标，不能在中间截断。
    while (next < end &&
        (blocks[next - base - 1] as Map).containsKey('sourceCursor') &&
        blocks[next - base - 1]['sourceCursor'] == null) {
      next++;
    }
    final cursor = next == end
        ? latest['cursor'] as int
        : (blocks[next - base - 1]['sourceCursor'] ?? next) as int;
    if (next > from) {
      final part = await _writeCheckpointSegment(
        path,
        blocks.sublist(from - base, next - base),
        from,
        cursor,
        budget,
        repair: repair,
      );
      if (part == null) {
        // 单个不可拆的测量组超过预算时跳过这一组，后续组仍能继续进入缓存。
        // 不发布缺行区间；新后缀有可用页界之前，磁盘上的旧清单仍然有效。
        parts.clear();
        total = 0;
      } else {
        parts.add(part);
        total += part['bytes'] as int;
      }
    }
    while (total > budget && parts.isNotEmpty) {
      total -= parts.removeAt(0)['bytes'] as int;
    }
    final start = parts.isEmpty ? 0 : parts.first['from'] as int;
    final usable = [
      for (final point in points)
        if (point[1] - 1 >= start && point[1] < next) point,
    ];
    if ((parts.isNotEmpty && (start == 0 || usable.isNotEmpty)) ||
        (blocks.isEmpty && base == 0)) {
      await _publishCheckpointManifest(path, parts, {
        ...metadata,
        'cursor': cursor,
        if (usable.isNotEmpty) 'pageRestarts': usable,
      }, total);
    }
    from = next;
  } while (from < end);
}

// isolate 入口只接收一个分段及小清单，不能捕获 latest 的整章对象图。
Future<Map<String, dynamic>?> _checkpointManifest(String path) =>
    Isolate.run(() {
      try {
        return FileLayoutCheckpointStore._manifest(path);
      } on Object {
        return null;
      }
    });

Future<Map<String, dynamic>?> _writeCheckpointSegment(
  String path,
  List<dynamic> rows,
  int from,
  int cursor,
  int budget, {
  required bool repair,
}) => Isolate.run(() {
  final bytes = utf8.encode(jsonEncode(rows));
  if (bytes.length > budget) return null;
  final digest = sha256.convert(bytes).toString();
  final file = File(p.join(path, '$digest.segment.gz'));
  if (repair || !file.existsSync()) {
    Directory(path).createSync(recursive: true);
    final temporary = File('${file.path}.pending');
    temporary.writeAsBytesSync(gzip.encode(bytes), flush: true);
    temporary.renameSync(file.path);
  }
  return {
    'from': from,
    'sha256': digest,
    'bytes': bytes.length,
    'count': rows.length,
    'cursor': cursor,
  };
});

Future<void> _publishCheckpointManifest(
  String path,
  List<Map<String, dynamic>> parts,
  Map<String, Object?> metadata,
  int total,
) => Isolate.run(() {
  String payload() => jsonEncode({
    'version': 16,
    'metadata': metadata,
    'parts': parts,
    'bytes': total,
  });
  var encoded = payload();
  // 极长单段可能产生很多页界；保留最近的页界，而不是停止更新整份缓存。
  var points = metadata['pageRestarts'] as List? ?? const [];
  while (utf8.encode(encoded).length > 256 * 1024 && points.length > 1) {
    points = points.sublist(points.length ~/ 2);
    metadata['pageRestarts'] = points;
    encoded = payload();
  }
  // 分段描述本身也占清单空间。若它达到上限，同样淘汰旧分段，不能冻结清单。
  while (utf8.encode(encoded).length > 256 * 1024 && parts.length > 1) {
    final count = (parts.length ~/ 4).clamp(1, parts.length - 1);
    for (final part in parts.take(count)) {
      total -= part['bytes'] as int;
    }
    parts.removeRange(0, count);
    final start = parts.first['from'] as int;
    points = points.where((point) => (point as List)[1] - 1 >= start).toList();
    if (points.isEmpty) return;
    metadata['pageRestarts'] = points;
    encoded = payload();
  }
  if (utf8.encode(encoded).length > 256 * 1024) return;
  Directory(path).createSync(recursive: true);
  final temporary = File(p.join(path, 'manifest.pending'));
  temporary.writeAsStringSync(
    jsonEncode([sha256.convert(utf8.encode(encoded)).toString(), encoded]),
    flush: true,
  );
  temporary.renameSync(p.join(path, 'manifest.json'));
});
