import 'document_platform.dart';

enum LocalFilePurpose {
  books,
  fonts;

  Set<String> get extensions => this == fonts
      ? const {'ttf', 'otf', 'ttc'}
      : const {'txt', 'epub', 'mobi', 'azw3', 'pdf'};
  String get emptyMessage => this == fonts
      ? '没有找到 TTF、OTF、TTC 字体文件'
      : '没有找到 TXT、EPUB、MOBI、AZW3、PDF 文件';
}

/// 手机共享存储中的目录或书籍，路径只在设备文件服务中使用。
class LocalBookEntry {
  const LocalBookEntry({
    required this.path,
    required this.name,
    required this.directory,
    required this.size,
    required this.modified,
    required this.sortName,
    this.count = -1,
    this.stamp = '',
  });
  final String path;
  final String name;
  final bool directory;
  final int size;
  final DateTime modified;
  final String sortName;
  final int count;

  /// 系统属性组合，包含纳秒时间及文件身份；只用来发现变化，不证明内容相同。
  final String stamp;
  String get extension => name.split('.').last.toLowerCase();
  String get title =>
      directory ? name : name.substring(0, name.lastIndexOf('.'));
  String get initial {
    final first = sortName.isEmpty ? '#' : sortName[0].toUpperCase();
    return RegExp('[A-Z]').hasMatch(first) ? first : '#';
  }

  PickedDocument get document => PickedDocument(
    uri: Uri.file(path).toString(),
    name: name,
    sizeBytes: size,
  );
}

abstract class LocalBookFiles {
  Future<bool> hasAccess();
  Future<bool> requestAccess();
  Future<List<LocalBookEntry>> roots();
  Future<List<LocalBookEntry>> list(
    String path, {
    bool counts = true,
    Set<String> extensions = const {'txt', 'epub', 'mobi', 'azw3', 'pdf'},
  });
  Future<void> delete(String path);
  Future<LocalFileInspection> inspect(List<String> paths);

  /// 系统索引的独立变化标记，不能与目录扫描的文件数直接比较。
  Future<String?> indexStamp(Set<String> extensions);
}

class LocalFileInspection {
  const LocalFileInspection({
    this.entries = const [],
    this.missing = const {},
    this.unavailable = const {},
  });
  final List<LocalBookEntry> entries;
  final Set<String> missing;
  final Set<String> unavailable;
}
