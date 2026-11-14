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
       directory = p.join(
         cacheRoot,
         'reading',
         bookId,
         digest,
         _contentRevision,
       ),
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

  // content30：四边定位进入样式表；正文归属排除已裁掉的标签间空白。
  // 正文写入和对外图片路径必须共用版本，避免升级后图片写在新目录、读旧目录。
  // content31：MathML 显示结构和来源节点编号随章节缓存。
  // content32：CSS 背景资源的来源路径和条件样式依赖随章节保存。
  // content33：body 相对字号按完整继承链计算，作废此前缺少外层倍率的样式。
  // content34：hr 浏览器默认样式进入统一样式表。
  // content36：旧式 HTML 字号改为正文加固定差值，并保留按当前字号重算的来源。
  // content37：hr currentColor 特殊绘色；强制重建缺少标题声明资料的旧缓存。
  // content39：章首显示索引同步、代码源码断行及标签边界缩进、NBSP留白和脚注配对。
  // content41：中英文括号编号与明确回链身份；继承属性按统一注册表传递。
  // content43：旧式HTML颜色/对齐与圈码脚注；正文和块号保持不变。
  // content44：列表内段落编号、旧式p对齐与空白段断点重新核对。
  // content45：hidden 空章题不再产生边距，旧章节原地补齐显示来源。
  // content46：保留解析后的字体族候选和章内 @font-face 资料。
  // content47：保存图片脚注的目标地址，正文字符与位置不变。
  static const _contentRevision = 'content47';
  static final processEpoch = DateTime.now().microsecondsSinceEpoch.toString();
  static const budget = 64 * 1024 * 1024;
  final String root, directory, epoch;
  final _id =
      '$pid-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';
  final _chapters = <String, Set<String>>{};
  final _readingChapters = <String, Set<String>>{};
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
      p.join(cacheRoot, 'reading', bookId, digest, _contentRevision, 'assets');

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
    _trimChapters();
    _preparing.clear();
    _saveLease();
  }

  bool get hasReadingChapters => _readingChapters.isNotEmpty;

  /// 阅读器和动画各自持有窗口，近期章节的LRU不能挤掉仍在使用的图片。
  void retainReadingChapters(String owner, Iterable<String> chapters) {
    final ids = chapters.toSet();
    if (ids.isEmpty) {
      _readingChapters.remove(owner);
    } else {
      _readingChapters[owner] = ids;
    }
    _trimChapters();
    _saveLease();
  }

  void _trimChapters() {
    final held = _readingChapters.values.expand((ids) => ids).toSet();
    while (_chapters.length > 4) {
      final idle = _chapters.keys.where((id) => !held.contains(id)).firstOrNull;
      if (idle == null) break;
      _chapters.remove(idle);
    }
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

  /// 缩略图写入期间由整书任务保护，写好即可参与回收。正文资源通常需保留到章节登记。
  /// 使用独立临时文件，多个后台任务可以同时生成同一份不可变资源。
  void write(File target, List<int> bytes, {bool retainUntilPinned = true}) {
    assert(retainUntilPinned || _preparationDepth > 0);
    if (retainUntilPinned) preparing(target);
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
        // 升级后旧版正文目录（content13 等）可能还在，一并清掉；保留 assets。
        for (final entry
            in source.listSync(followLinks: false).whereType<Directory>()) {
          if (!p.basename(entry.path).startsWith('content')) continue;
          final chapters = Directory(p.join(entry.path, 'chapters'));
          if (chapters.existsSync()) chapters.deleteSync(recursive: true);
        }
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
