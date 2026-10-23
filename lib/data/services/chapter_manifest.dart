import '../../domain/models/source_content_index.dart';

/// 阅读目录所需的清单资料和已解析索引，不把同一索引再编码/解析一遍。
/// 新清单只传目录所需字段；旧书要修复目录时，data 保留完整原始清单。
class ChapterManifest {
  ChapterManifest(this.data, [SourceContentIndex? index]) : _index = index;

  final Map<String, dynamic> data;
  SourceContentIndex? _index;

  SourceContentIndex? get sourceIndex {
    final raw = data['sourceIndex'];
    return _index ??= raw is Map
        ? SourceContentIndex.fromJson(raw.cast<String, dynamic>())
        : null;
  }
}
