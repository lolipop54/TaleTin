part of 'indexed_chapter_reader.dart';

typedef _StoredSections = (PublicationSectionStore, PublicationSectionPlan);

class _PublicationDraft {
  _PublicationDraft(
    this.chapter,
    this.body,
    this.cuts,
    this.raw,
    this.path,
    this.legacyMobi,
  );

  final Chapter chapter;
  final ChapterContent body;
  final List<int> cuts;
  final Uint8List raw;
  final String path;
  final bool legacyMobi;
  late final slicer = PublicationSectionSlicer(body, cuts);
}

extension _IndexedPublicationSections on IndexedChapterReader {
  bool get _hasSpreadIndex =>
      !_fixedLayout && (index.format == 'mobi' || index.format == 'azw3');

  File _spreadIndexFile(String chapterId) => cache!.file(
    p.join(PublicationSectionStore.folder, chapterId, 'spread-starts.json'),
  );

  Future<List<SpreadChapterStart>?> _indexedSpreadStarts(
    Chapter chapter,
    DecodeBytes decode,
  ) async {
    if (!_hasSpreadIndex) return null;
    await verifySource();
    if (_spreadStarts[chapter.id] case final found?) return found;
    final file = _spreadIndexFile(chapter.id);
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw case [final String identity, final List rows]
          when identity == _spreadIdentity) {
        final starts = <SpreadChapterStart>[];
        var previous = 0;
        for (final row in rows) {
          if (row case [final String id, final int offset]
              when offset >= previous && offset < chapter.textLength) {
            starts.add((blockId: id, textOffset: offset));
            previous = offset;
          } else {
            throw const FormatException('双列章首索引无效');
          }
        }
        return _spreadStarts[chapter.id] = starts;
      }
    } on FileSystemException {
      // 首次查旧书时只转换候选正文，不准备图片或排版。
    } on FormatException {
      // 索引是派生文件，损坏时用同一份正文重新核实。
    }
    final store = cache!;
    await store.beginPreparation();
    try {
      final archive = _archive ??= openIndexedPublication(
        source.path,
        verification.file.parent.path,
        index,
      );
      final checked = await _readSectionBody(
        chapter,
        decode,
        archive,
        index.chapters[chapter.id]!.single as String,
      );
      _rememberSpreadStarts(checked.$1, replace: true);
      final starts = _spreadStarts[chapter.id]!;
      // 同一候选接着要排版时复用这次转换。只保留一份小型正文。
      _spreadProbe = starts.isNotEmpty && checked.$2.length <= 1024 * 1024
          ? checked
          : null;
      return starts;
    } finally {
      store.endPreparation();
    }
  }

  void _rememberSpreadStarts(ChapterContent body, {bool replace = false}) {
    if (!_hasSpreadIndex || _spreadStarts.containsKey(body.chapterId)) return;
    final ids = declaredPublicationSpreadStarts(body).toSet();
    final starts = <SpreadChapterStart>[];
    if (ids.isNotEmpty) {
      var offset = 0;
      for (final block in body.blocks) {
        if (ids.contains(block.id)) {
          starts.add((blockId: block.id, textOffset: offset));
        }
        offset += block.textLength;
      }
    }
    _spreadStarts[body.chapterId] = starts;
    final file = _spreadIndexFile(body.chapterId);
    // 热读取复用磁盘上的短索引；验证失败的旧记录由专门的索引读取重建。
    if (!replace && file.existsSync()) return;
    try {
      cache!.write(
        file,
        utf8.encode(
          jsonEncode([
            _spreadIdentity,
            [
              for (final start in starts) [start.blockId, start.textOffset],
            ],
          ]),
        ),
        retainUntilPinned: false,
      );
    } on FileSystemException {
      // 无可写缓存时仍可使用本次核实的章首。
    }
  }

  Future<_StoredSections?> _publicationSections(
    Chapter chapter,
    DecodeBytes decode, {
    bool rebuild = false,
    bool prioritizeLayout = false,
  }) async {
    if (index.format != 'epub' &&
        index.format != 'mobi' &&
        index.format != 'azw3') {
      return null;
    }
    if (_fixedLayout) return null;
    await verifySource();
    if (rebuild) {
      _sectionPlans.remove(chapter.id);
      _sectionDrafts.remove(chapter.id);
    }
    final existing = rebuild ? null : _sectionPlans.remove(chapter.id);
    if (existing != null) {
      _sectionPlans[chapter.id] = existing;
      final draft = _sectionDrafts[chapter.id];
      if (!prioritizeLayout && draft != null && existing.$2.anchors.isEmpty) {
        return _persistPublicationDraft(draft);
      }
      return existing;
    }
    final permanent = PublicationSectionStore(
      verification.file.parent.path,
      chapter.id,
      index.sourceDigest,
    );
    final local = PublicationSectionStore(
      cache!.directory,
      chapter.id,
      index.sourceDigest,
    );
    if (!rebuild) {
      final shared = _sectionReadRoot;
      for (final store in [
        local,
        permanent,
        if (shared != null)
          PublicationSectionStore(
            p.join(
              shared,
              'reading',
              p.relative(cache!.directory, from: cache!.root),
            ),
            chapter.id,
            index.sourceDigest,
          ),
      ]) {
        if (store.plan(chapter) case final ready?) {
          return _rememberPlan(chapter.id, (store, ready));
        }
      }
    }
    final path = index.chapters[chapter.id]!.single as String;
    // Kindle 已经按 HTML 大小切过文件，但一个文件仍可能包含多个实际回目。
    final shortKindleFile =
        index.format != 'epub' &&
        isKindleContinuation(path) &&
        chapter.textLength >= 24 * 1024 &&
        (index.tocPositions[chapter.id]?.length ?? 0) > 1;
    final archive = _archive ??= openIndexedPublication(
      source.path,
      verification.file.parent.path,
      index,
    );
    if (!shortKindleFile &&
        chapter.textLength < publicationSectionMinText &&
        (archive.find(path)?.size ?? 0) < publicationSectionMinHtml) {
      return null;
    }
    await cache!.beginPreparation();
    try {
      final probe = _spreadProbe;
      _spreadProbe = null;
      final (body, raw) = probe != null && probe.$1.chapterId == chapter.id
          ? probe
          : await _readSectionBody(chapter, decode, archive, path);
      _rememberSpreadStarts(body);
      final shortFile =
          chapter.textLength < publicationSectionMinText &&
          (archive.find(path)?.size ?? 0) < publicationSectionMinHtml;
      final starts =
          body.displaySourceJson?['tocSpreadStarts'] as List? ?? const [];
      final cuts = shortFile && starts.length < 2
          ? const <int>[]
          : publicationSectionBoundaries(
              body,
              target: shortFile ? 8 * 1024 : publicationSectionTarget,
            );
      if (prioritizeLayout && cuts.isNotEmpty) {
        _sectionDrafts[chapter.id] = _PublicationDraft(
          chapter,
          body,
          cuts,
          raw,
          path,
          archive.legacyMobi,
        );
        while (_sectionDrafts.length > 1 &&
            _sectionDrafts.values.fold<int>(
                  0,
                  (size, draft) => size + draft.raw.length,
                ) >
                8 * 1024 * 1024) {
          final oldest = _sectionDrafts.keys.first;
          _sectionDrafts.remove(oldest);
          _sectionPlans.remove(oldest);
        }
        return _rememberPlan(chapter.id, (
          local,
          PublicationSectionPlan.draft(body, cuts, index.sourceDigest),
        ));
      }
      final anchors = cuts.isEmpty
          ? const <String, (String, int)>{}
          : publicationSectionAnchors(
              decodeTextBytes(raw),
              chapter,
              path,
              images: index.images.keys.toSet(),
              legacyMobi: archive.legacyMobi,
            );
      return _rememberPlan(chapter.id, (
        local,
        local.write(body, cuts, anchors),
      ));
    } on FileSystemException {
      if (!rebuild) return null;
      rethrow;
    } finally {
      cache!.endPreparation();
    }
  }

  Future<bool> _savePublicationDraft(Chapter preferred) async {
    final draft =
        _sectionDrafts[preferred.id] ?? _sectionDrafts.values.lastOrNull;
    if (draft == null) return false;
    await _persistPublicationDraft(draft);
    return _sectionDrafts.isNotEmpty;
  }

  Future<_StoredSections> _persistPublicationDraft(
    _PublicationDraft draft,
  ) async {
    await verifySource();
    final cache = this.cache!;
    await cache.beginPreparation();
    try {
      final store = PublicationSectionStore(
        cache.directory,
        draft.chapter.id,
        index.sourceDigest,
      );
      final anchors = publicationSectionAnchors(
        decodeTextBytes(draft.raw),
        draft.chapter,
        draft.path,
        images: index.images.keys.toSet(),
        legacyMobi: draft.legacyMobi,
      );
      try {
        final ready = store.write(draft.body, draft.cuts, anchors);
        _sectionDrafts.remove(draft.chapter.id);
        return _rememberPlan(draft.chapter.id, (store, ready));
      } on FileSystemException {
        // 无法落盘时，目录和正在阅读的小节仍可从同一份内存正文取得。
        final plan = _sectionPlans[draft.chapter.id]!.$2;
        return _rememberPlan(draft.chapter.id, (
          store,
          PublicationSectionPlan(
            plan.rows,
            anchors,
            plan.chapterStarts,
            plan.headings,
            sourceDigest: plan.sourceDigest,
            inMemory: true,
          ),
        ));
      }
    } finally {
      cache.endPreparation();
    }
  }

  Future<(ChapterContent, Uint8List)> _readSectionBody(
    Chapter chapter,
    DecodeBytes decode,
    EpubArchive archive,
    String path,
  ) async {
    archive.resetTotalBudget();
    final raw = archive.readBytes(path);
    final body = await read(chapter, decode, deferImages: true, inputHtml: raw);
    return (prepareSpreadChapters(body), raw);
  }

  _StoredSections _rememberPlan(String chapterId, _StoredSections value) {
    _sectionPlans.remove(chapterId);
    _sectionPlans[chapterId] = value;
    if (_sectionPlans.length > 4) {
      final oldest = _sectionPlans.keys.first;
      _sectionPlans.remove(oldest);
      _sectionDrafts.remove(oldest);
    }
    return value;
  }

  Future<ChapterContent> _readPublicationSection(
    Chapter chapter,
    int section,
    DecodeBytes decode, {
    required bool prioritizeLayout,
    required bool countOnly,
  }) async {
    final store = cache!;
    if (!countOnly) await store.beginPreparation();
    try {
      var cached = await _publicationSections(
        chapter,
        decode,
        prioritizeLayout: prioritizeLayout,
      );
      if (cached == null || section >= cached.$2.rows.length) {
        throw const ContentFailure(ContentErrorCode.corrupted, '正文分段索引已改变');
      }
      late ChapterContent content;
      try {
        content =
            _sectionDrafts[chapter.id]?.slicer.read(section) ??
            cached.$1.read(section, cached.$2.rows[section]);
      } on Object catch (error) {
        if (error is! FormatException &&
            error is! FileSystemException &&
            error is! TypeError) {
          rethrow;
        }
        cached = await _publicationSections(
          chapter,
          decode,
          rebuild: true,
          prioritizeLayout: prioritizeLayout,
        );
        if (cached == null || section >= cached.$2.rows.length) rethrow;
        content =
            _sectionDrafts[chapter.id]?.slicer.read(section) ??
            cached.$1.read(section, cached.$2.rows[section]);
      }
      if (countOnly) {
        _prepareSectionImageSizes(content);
      } else {
        await bindStyles();
        await prepareResources(content, sectionKey: '${chapter.id}@$section');
      }
      return _fillSectionImageDimensions(content);
    } finally {
      if (!countOnly) store.endPreparation();
    }
  }

  void _prepareSectionImageSizes(ChapterContent content) {
    for (final block in content.blocks) {
      for (final resource in [
        block.resourcePath,
        ...block.inlineImages.map((e) => e.resourcePath),
      ]) {
        if (resource == null || !resource.startsWith('res/')) continue;
        final entry = resource.substring(4);
        final size = index.images[entry];
        if (size == null ||
            (size.first >= 0 &&
                (size.length > 2 || !entry.toLowerCase().endsWith('.svg')))) {
          continue;
        }
        final archive = _archive ??= openIndexedPublication(
          source.path,
          verification.file.parent.path,
          index,
        );
        final dimensions = sniffImageSize(archive.readBytes(entry));
        index.images[entry] = [
          ...dimensions.toIndex(),
          if (dimensions.svgRatioOnly == null &&
              entry.toLowerCase().endsWith('.svg'))
            0,
        ];
      }
    }
  }

  ChapterContent _fillSectionImageDimensions(ChapterContent content) {
    ContentBlock fill(ContentBlock block) {
      if (block.resourcePath == null && block.inlineImages.isEmpty) {
        return block;
      }
      List<int>? dimensions(String path) =>
          path.startsWith('res/') ? index.images[path.substring(4)] : null;
      final box = block.resourcePath == null
          ? null
          : dimensions(block.resourcePath!);
      return ContentBlock.fromJson({
        ...block.toJson(),
        if (box != null) 'width': box[0],
        if (box != null) 'height': box[1],
        if (box != null) 'svgRatioOnly': box.length > 2 && box[2] == 1,
        if (block.inlineImages.isNotEmpty)
          'iim': [
            for (final image in block.inlineImages)
              (image.toJson()..addAll({
                if (dimensions(image.resourcePath) case final size?) ...{
                  'w': size[0],
                  'h': size[1],
                },
              })),
          ],
      });
    }

    return ChapterContent(
      chapterId: content.chapterId,
      blocks: [for (final block in content.blocks) fill(block)],
      tables: content.tables,
      epubDetailsRevision: content.epubDetailsRevision,
      stylesJson: content.stylesJson,
      displaySourceJson: content.displaySourceJson,
    );
  }
}
