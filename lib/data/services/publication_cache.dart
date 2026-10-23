import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 各格式、两种排版共用的可重建正文与资源。当前章及近期所需文件先登记
/// 再回收，另一后台任务不能删掉仍在显示的图片。
class PublicationCache {
  PublicationCache(
    String cacheRoot,
    String bookId,
    String digest, {
    String? epoch,
  }) : root = p.join(cacheRoot, 'reading'),
       directory = p.join(cacheRoot, 'reading', bookId, digest, 'content2'),
       epoch = epoch ?? processEpoch {
    // 上一版的MOBI缓存可以直接沿用，避免升级后保留两份相同的读过内容。
    final previous = Directory(
      p.join(cacheRoot, 'mobi', bookId, digest, 'publication2'),
    );
    if (previous.existsSync() && !Directory(directory).existsSync()) {
      try {
        Directory(p.dirname(directory)).createSync(recursive: true);
        previous.renameSync(directory);
      } on FileSystemException {
        // 两个后台会话可能同时打开；移动失败时仍可从原书按需重建。
      }
    }
  }

  static final processEpoch = DateTime.now().microsecondsSinceEpoch.toString();
  static const budget = 64 * 1024 * 1024;
  final String root, directory, epoch;
  final _id =
      '$pid-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';
  final _chapters = <String, Set<String>>{};
  final _preparing = <String>{};
  int _added = 0;
  bool _checked = false;
  bool _closed = false;
  int _preparationDepth = 0;
  Future<void>? _registration;
  Set<String> _savedPaths = {};
  bool _leaseAvailable = true;
  String get _lease => p.join(root, '.pins', '$epoch-$_id.json');
  File get _trimGuard => File(p.join(root, '.pins', '$epoch-trimming.lock'));

  static String effectiveRoot(String libraryRoot, String? cacheRoot) =>
      cacheRoot ?? p.join(p.dirname(libraryRoot), 'cache');
  static String assets(String cacheRoot, String bookId, String digest) =>
      p.join(cacheRoot, 'reading', bookId, digest, 'content2', 'assets');

  File file(String relative) {
    final path = p.normalize(p.join(directory, relative));
    if (!p.isWithin(directory, path)) throw const FormatException('阅读缓存路径越界');
    return File(path);
  }

  void preparing(File file) {
    _preparing.add(file.path);
    _saveLease();
  }

  /// 一个章节或一批并发资源准备期间，先保护本书目录；不用为每张图片
  /// 重写一次保护记录。任务结束才发布实际所需文件，再执行容量回收。
  Future<void> beginPreparation() {
    _preparationDepth++;
    return _preparationDepth == 1
        ? _registration = _registerPreparation()
        : _registration!;
  }

  Future<void> _registerPreparation() async {
    final guard = _trimGuard;
    var acquired = false;
    try {
      guard.parent.createSync(recursive: true);
      while (!acquired) {
        try {
          // exclusive创建对同进程的不同isolate同样互斥；Dart在Linux上的
          // FileLock只属于进程，不能用来隔开这些后台任务。
          guard.createSync(exclusive: true);
          acquired = true;
        } on FileSystemException {
          if (!guard.existsSync()) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      // 清理结束后先登记整书保护，再检查／读取缓存，避免命中后被删除。
      _saveLease();
    } on FileSystemException {
      _leaseAvailable = false;
    } finally {
      if (acquired) guard.deleteSync();
    }
  }

  void endPreparation() {
    assert(_preparationDepth > 0);
    _preparationDepth--;
    if (_preparationDepth == 0) {
      _saveLease();
      trim();
    }
  }

  void pin(String chapter, Iterable<File> files) {
    _chapters.remove(chapter);
    _chapters[chapter] = files.map((file) => file.path).toSet();
    while (_chapters.length > 4) {
      _chapters.remove(_chapters.keys.first);
    }
    _preparing.clear();
    _saveLease();
  }

  void _saveLease() {
    final file = File(_lease);
    final paths = _preparationDepth > 0
        ? {directory}
        : {..._preparing, ..._chapters.values.expand((paths) => paths)};
    if (paths.any((path) => !p.isWithin(root, path))) {
      throw const FormatException('阅读缓存保护路径越界');
    }
    if (_leaseAvailable &&
        paths.length == _savedPaths.length &&
        paths.containsAll(_savedPaths)) {
      return;
    }
    try {
      file.parent.createSync(recursive: true);
      final temporary = File('${file.path}.next');
      temporary.writeAsStringSync(jsonEncode(paths.toList()), flush: false);
      temporary.renameSync(file.path);
      _savedPaths = paths;
      _leaseAvailable = true;
    } on FileSystemException {
      // 磁盘不足等缓存故障不能阻止TXT／纯文字章节直接读取原书。
      // 保护记录未发布时，本会话不清理其他文件；后续写入可重新尝试。
      _leaseAvailable = false;
    }
  }

  /// Pin before publishing. A unique temporary path allows two independent
  /// workers to prepare the same immutable asset without sharing a .pending.
  void write(File target, List<int> bytes) {
    preparing(target);
    target.parent.createSync(recursive: true);
    final next = File('${target.path}.$epoch.$_id.pending');
    try {
      next.writeAsBytesSync(bytes, flush: false);
      try {
        next.renameSync(target.path);
      } on FileSystemException {
        if (!target.existsSync()) rethrow;
        next.deleteSync();
      }
      _added += bytes.length;
    } finally {
      if (next.existsSync()) next.deleteSync();
    }
  }

  /// 复用旧的可重建文件。仅在来源已核对后调用，不移动持久封面或业务数据。
  bool adopt(File previous, File target) {
    if (!previous.existsSync()) return target.existsSync();
    preparing(target);
    target.parent.createSync(recursive: true);
    try {
      previous.renameSync(target.path);
      _added += target.lengthSync();
      return true;
    } on FileSystemException {
      // 另一侧已经接走同一文件时使用新文件，不能让并发转换造成读章失败。
      return target.existsSync();
    }
  }

  /// 正文任务已交接后只清章节JSON；正在显示的原书资源另由书籍会话保护。
  static void clearChapters(String cacheRoot, [String? bookId]) {
    final root = Directory(p.join(cacheRoot, 'reading'));
    if (!root.existsSync()) return;
    final books = bookId == null
        ? root.listSync(followLinks: false).whereType<Directory>()
        : [Directory(p.join(root.path, bookId))];
    for (final book in books) {
      if (!book.existsSync() || p.basename(book.path) == '.pins') continue;
      for (final source
          in book.listSync(followLinks: false).whereType<Directory>()) {
        final chapters = Directory(p.join(source.path, 'content2', 'chapters'));
        if (chapters.existsSync()) chapters.deleteSync(recursive: true);
      }
    }
  }

  void trim({bool force = false}) {
    if (_preparationDepth > 0 || !_leaseAvailable) return;
    if (!force && _checked && _added < 8 * 1024 * 1024) return;
    final directory = Directory(root);
    if (!directory.existsSync()) return;
    final guard = _trimGuard;
    var locked = false;
    try {
      guard.parent.createSync(recursive: true);
      // 清理不排队；只在能立即取得发布保护记录的互斥文件时执行。
      // 文件名含进程epoch，进程异常退出也不会阻塞下一次启动。
      guard.createSync(exclusive: true);
      locked = true;
      final protected = <String>{};
      final pins = Directory(p.join(root, '.pins'));
      if (pins.existsSync()) {
        for (final file
            in pins.listSync(followLinks: false).whereType<File>()) {
          if (!p.basename(file.path).startsWith('$epoch-')) {
            // All writable workers receive the main process epoch. Read-only
            // listening workers never create leases. Prior-process leases can
            // therefore be reclaimed without expiring an active reader.
            try {
              file.deleteSync();
            } on FileSystemException {
              /* Closing. */
            }
            continue;
          }
          if (!file.path.endsWith('.json')) {
            continue;
          }
          try {
            for (final path in jsonDecode(file.readAsStringSync()) as List) {
              if (path is String && p.isWithin(root, path)) protected.add(path);
            }
          } on FileSystemException {
            // Another worker has closed; its lease no longer protects a file.
          } on FormatException {
            // Failed atomic lease read: leave cache intact for this round.
            return;
          }
        }
      }
      final files = <(File, int, DateTime)>[];
      var total = 0;
      for (final file
          in directory
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        if (p.isWithin(p.join(root, '.pins'), file.path) ||
            p.basename(file.path) == '.trim-lock' ||
            file.path.endsWith('.pending')) {
          continue;
        }
        try {
          final stat = file.statSync();
          if (stat.type != FileSystemEntityType.file) continue;
          total += stat.size;
          files.add((file, stat.size, stat.modified));
        } on FileSystemException {
          /* A parallel trim already removed it. */
        }
      }
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final entry in files) {
        if (total <= budget) break;
        if (protected.any(
          (path) => path == entry.$1.path || p.isWithin(path, entry.$1.path),
        )) {
          continue;
        }
        try {
          entry.$1.deleteSync();
          total -= entry.$2;
        } on FileSystemException {
          /* In use or already reclaimed. */
        }
      }
      _checked = true;
      _added = 0;
    } on FileSystemException {
      // Cleanup cannot turn a prepared chapter into a reading failure.
    } finally {
      if (locked) guard.deleteSync();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final file = File(_lease);
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 缓存关闭不影响源书交接；下次进程启动会回收旧保护记录。
    }
    if (_checked || _added > 0 || _chapters.isNotEmpty) trim(force: true);
  }
}
