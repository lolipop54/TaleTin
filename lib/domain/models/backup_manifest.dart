/// 备份格式与数据库版本独立演进；外部输入只接受明确支持的格式。
class BackupManifest {
  BackupManifest({
    required this.databaseVersion,
    required this.createdAt,
    required this.bookCount,
    required List<BackupEntry> files,
    this.storageVersion = 1,
  }) : files = List.unmodifiable(files);

  static const formatVersion = 2;
  final int storageVersion;
  static const maxFiles = 200000;
  static const maxBytes = 32 * 1024 * 1024 * 1024;
  final int databaseVersion;
  final DateTime createdAt;
  final int bookCount;
  final List<BackupEntry> files;
  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);

  Map<String, Object> toJson() => {
    'format': 'gtreader-backup',
    'formatVersion': storageVersion,
    'databaseVersion': databaseVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'bookCount': bookCount,
    'files': files.map((f) => f.toJson()).toList(),
  };

  factory BackupManifest.fromJson(
    Object? value, {
    required int supportedDatabaseVersion,
  }) {
    if (value is! Map<String, dynamic> ||
        value['format'] != 'gtreader-backup' ||
        (value['formatVersion'] != 1 && value['formatVersion'] != 2)) {
      throw const FormatException('不支持的备份格式版本');
    }
    final database = value['databaseVersion'];
    final count = value['bookCount'];
    final rawFiles = value['files'];
    final date = value['createdAt'];
    if (database is! int ||
        database < 1 ||
        database > supportedDatabaseVersion) {
      throw const FormatException('备份的数据库版本不受支持，请检查应用版本');
    }
    if (count is! int ||
        count < 0 ||
        rawFiles is! List ||
        rawFiles.isEmpty ||
        rawFiles.length > maxFiles ||
        date is! String ||
        DateTime.tryParse(date) == null) {
      throw const FormatException('备份清单不完整或超出支持范围');
    }
    final files = rawFiles.map(BackupEntry.fromJson).toList();
    final paths = <String>{};
    var bytes = 0;
    for (final file in files) {
      // Android 文件名区分大小写，原书中大小写不同的资源必须完整保留。
      if (!paths.add(file.path)) throw const FormatException('备份含重名文件');
      bytes += file.size;
      if (bytes > maxBytes) throw const FormatException('备份解压体积超过 32 GiB');
    }
    if (!paths.contains('database/reader.sqlite')) {
      throw const FormatException('备份缺少数据库');
    }
    return BackupManifest(
      databaseVersion: database,
      createdAt: DateTime.parse(date),
      bookCount: count,
      files: files,
      storageVersion: value['formatVersion'] as int,
    );
  }
}

class BackupEntry {
  const BackupEntry({
    required this.path,
    required this.size,
    required this.sha256,
  });
  final String path;
  final int size;
  final String sha256;
  Map<String, Object> toJson() => {
    'path': path,
    'size': size,
    'sha256': sha256,
  };

  factory BackupEntry.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) throw const FormatException('无效的文件清单');
    final path = value['path'];
    final size = value['size'];
    final hash = value['sha256'];
    if (path is! String ||
        !isSafePath(path) ||
        size is! int ||
        size < 0 ||
        size > BackupManifest.maxBytes ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('备份文件路径、体积或校验和无效');
    }
    return BackupEntry(path: path, size: size, sha256: hash);
  }

  static bool isSafePath(String path) {
    if (path.length > 1024 || path.contains(RegExp(r'[\\:\x00-\x1f]'))) {
      return false;
    }
    final parts = path.split('/');
    if (parts.any((s) => s.isEmpty || s == '.' || s == '..')) return false;
    return path == 'database/reader.sqlite' ||
        (parts.length >= 2 &&
            (parts.first == 'library' || parts.first == 'fonts'));
  }
}
