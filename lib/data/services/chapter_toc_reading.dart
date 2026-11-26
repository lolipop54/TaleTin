part of '../repositories/file_chapter_content_repository.dart';

extension _ChapterTocReading on FileChapterContentRepository {
  Future<List<TocNode>> _readToc(String bookId, int contentVersion) async {
    final key = '$bookId/$contentVersion';
    if (_tocKey == key && _toc != null) return _toc!;
    final file = File(
      p.join(
        libraryRoot,
        bookId,
        'content',
        '$contentVersion',
        'manifest.json',
      ),
    );
    var nodes = const <TocNode>[];
    var chapters = const <Chapter>[];
    var encoding = '';
    Map<String, dynamic>? manifest;
    TocLocations? locations;
    if (await file.exists()) {
      try {
        final snapshot = await _manifest(p.dirname(file.path));
        final decoded = snapshot?.data;
        if (decoded != null) {
          manifest = decoded;
          if (snapshot!.sourceIndex case final index?) {
            locations = (
              anchors: index.tocPositions,
              headings: index.tocHeadings,
            );
          }
          encoding = decoded['encoding'] as String? ?? '';
          final rawToc = decoded['toc'];
          if (rawToc is List) {
            nodes = [
              for (final raw in rawToc)
                if (raw is Map) TocNode.fromJson(raw.cast<String, Object?>()),
            ];
          }
          final rawChapters = decoded['chapters'];
          if (rawChapters is List) {
            chapters = [
              for (final raw in rawChapters)
                if (raw is Map)
                  Chapter(
                    id: raw['id'] as String? ?? '',
                    ordinal: (raw['ordinal'] as num?)?.toInt() ?? 0,
                    title: raw['title'] as String? ?? '',
                    contentPath: raw['path'] as String? ?? '',
                    textLength: (raw['textLength'] as num?)?.toInt() ?? 0,
                    href: raw['href'] as String?,
                  ),
            ];
          }
        }
      } on FormatException {
        // 目录读不出来不阻断阅读：界面降级为章节平铺
        nodes = const [];
      }
    }
    // 新导入已生成完整目录。旧书按目录版本和正文格式判断需要补哪些资料。
    if (chapters.isNotEmpty && manifest != null && needsTocRecovery(manifest)) {
      final epub = chapters.any((chapter) => chapter.href != null);
      final directory = p.join(libraryRoot, bookId);
      final rawIndex = manifest['sourceIndex'];
      final index = rawIndex is Map
          ? SourceContentIndex.fromJson(rawIndex.cast<String, dynamic>())
          : null;
      var source = File(
        bookSourcePath(directory, index?.format ?? (epub ? 'epub' : 'txt')),
      );
      if (index == null && epub && !await source.exists()) {
        for (final format in ['mobi', 'azw3']) {
          final file = File(bookSourcePath(directory, format));
          if (await file.exists()) {
            source = file;
            break;
          }
        }
      }
      if (await source.exists()) {
        try {
          final previousNodes = nodes;
          if (epub) {
            final recovered = await recoverPublicationToc(
              sourcePath: source.path,
              bookDirectory: directory,
              contentDirectory: file.parent.path,
              chapters: chapters,
              existing: nodes,
              previousRevision: (manifest['tocRevision'] as num?)?.toInt() ?? 0,
              index: index,
            );
            if (recovered.isNotEmpty) nodes = recovered;
          } else {
            nodes = await recoverTxtToc(
              bookDirectory: directory,
              chapters: chapters,
              nodes: nodes,
              encoding: encoding,
              preparation: textPreparation,
            );
          }
          // 目录和完成标记在同一次替换中保存，原有正文、块号和阅读位置继续使用。
          final next = File('${file.path}.next');
          await next.writeAsString(
            jsonEncode({
              ...manifest,
              'toc': nodes.map((node) => node.toJson()).toList(),
              'tocRevision': kTocRevision,
            }),
            flush: true,
          );
          await next.rename(file.path);
          _manifests.remove(p.dirname(file.path));
          if (!identical(nodes, previousNodes) &&
              isKindleTocFormat(
                index?.format ??
                    p
                        .extension(source.path)
                        .toLowerCase()
                        .replaceFirst('.', ''),
              )) {
            await (await _contentWorker()).invalidate(bookId);
          }
        } on Object {
          // 原文件或修复保存失败时仍可用旧目录，下次读取可以继续尝试。
        }
      }
    }
    _tocKey = key;
    _toc = nodes;
    _tocLocations = locations;
    return nodes;
  }
}
