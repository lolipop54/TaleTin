import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../domain/models/book_document.dart';
import '../../../domain/services/chapter_sections.dart';
import 'anchor_locator.dart';
import 'publication_style_tree.dart';
import 'publication_section_slices.dart';
import 'publication_spread_chapters.dart';

typedef PublicationSectionRow = ({
  String blockId,
  int offset,
  int length,
  String digest,
});

class PublicationSectionPlan {
  const PublicationSectionPlan(
    this.rows,
    this.anchors,
    this.chapterStarts,
    this.headings, {
    this.sourceDigest,
    this.inMemory = false,
  });

  final List<PublicationSectionRow> rows;
  final Map<String, (String, int)> anchors;
  final List<String> chapterStarts;
  final Map<String, String> headings;
  final String? sourceDigest;
  final bool inMemory;

  /// 同一来源和小节形状复用排版，内存小节落盘时不用重排当前页。
  String get layoutIdentity => jsonEncode([
    PublicationSectionStore.folder,
    sourceDigest,
    publicationCssMode,
    for (final row in rows) [row.blockId, row.offset, row.length],
    chapterStarts,
  ]);

  static Map<String, String> headingIds(ChapterContent body) {
    final headings = <String, String>{};
    for (final block in body.blocks) {
      if (block.kind != BlockKind.heading) continue;
      final text = block.runs.map((r) => r.text).join().trim();
      if (text.isNotEmpty) headings.putIfAbsent(text, () => block.id);
    }
    return headings;
  }

  static PublicationSectionPlan draft(
    ChapterContent body,
    List<int> cuts,
    String sourceDigest,
  ) {
    final rows = <PublicationSectionRow>[];
    var offset = 0;
    for (var i = 0; i + 1 < cuts.length; i++) {
      var length = 0;
      for (var j = cuts[i]; j < cuts[i + 1]; j++) {
        length += body.blocks[j].textLength;
      }
      rows.add((
        blockId: body.blocks[cuts[i]].id,
        offset: offset,
        length: length,
        digest: '',
      ));
      offset += length;
    }
    return PublicationSectionPlan(
      rows,
      const {},
      declaredPublicationSpreadStarts(body),
      headingIds(body),
      sourceDigest: sourceDigest,
      inMemory: true,
    );
  }
}

class PublicationChapterSections implements ChapterSections {
  PublicationChapterSections(
    this.identity,
    this.plan,
    this._readSection, {
    Future<ChapterContent> Function(int)? readForCount,
  }) : _readForCount = readForCount ?? _readSection,
       _numbers = [
         for (final row in plan.rows) sectionBlockNumber(row.blockId),
       ];

  @override
  final String identity;
  final PublicationSectionPlan plan;
  final List<int> _numbers;
  final Future<ChapterContent> Function(int) _readSection;
  final Future<ChapterContent> Function(int) _readForCount;
  @override
  Future<ChapterContent> readSection(int section) => _readSection(section);
  @override
  Future<ChapterContent> readSectionForCount(int section) =>
      _readForCount(section);

  @override
  int get count => plan.rows.length;
  @override
  String get firstBlockId => plan.rows.first.blockId;
  @override
  int offsetOf(int section) => plan.rows[section].offset;
  @override
  int forOffset(int offset) => sectionIndexAt(count, offset, offsetOf);
  @override
  int? orderOf(String blockId) {
    final number = sectionBlockNumber(blockId);
    return number > 0 ? number : null;
  }

  @override
  int forBlock(String blockId) =>
      sectionIndexAt(count, orderOf(blockId) ?? 0, (i) => _numbers[i]);

  @override
  String? get lastChapterStart => plan.chapterStarts.lastOrNull;

  @override
  String? chapterStartFor(String blockId) {
    final at = orderOf(blockId);
    if (at == null || plan.chapterStarts.isEmpty) return null;
    final start =
        plan.chapterStarts[sectionIndexAt(
          plan.chapterStarts.length,
          at,
          (i) => sectionBlockNumber(plan.chapterStarts[i]),
        )];
    return sectionBlockNumber(start) <= at ? start : null;
  }

  (String, int)? anchor(String fragment) {
    final exact = plan.anchors[fragment];
    if (exact != null || !fragment.contains('%')) return exact;
    try {
      return plan.anchors[Uri.decodeComponent(fragment)];
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

/// 分段可重建。文件先完整写入，最后发布清单，读者只接收同一来源的完整结果。
class PublicationSectionStore {
  PublicationSectionStore(String root, String chapterId, this.sourceDigest)
    : directory = p.join(root, folder, chapterId),
      chapterId = chapterId;

  static const folder = 'publication-sections-v5';
  static const derivedFolders = [
    folder,
    'publication-sections-v4',
    'publication-sections-v3',
    'publication-sections-v2',
    'publication-sections-v1',
  ];
  static const _sharedKeys = [
    'css',
    'styles',
    'backgroundResources',
    'fontSizeDeclarations',
    'fontFaces',
  ];
  static int _nonce = 0;
  final String directory, sourceDigest, chapterId;

  File get _manifest => File(p.join(directory, 'index.json'));
  File _piece(int i) => File(p.join(directory, '$i.json'));
  File get _shared => File(p.join(directory, 'shared.json'));
  Map<String, Object?>? _sharedData;

  PublicationSectionPlan? plan(Chapter chapter) {
    try {
      final raw = jsonDecode(_manifest.readAsStringSync()) as Map;
      if (raw['source'] != sourceDigest ||
          raw['length'] != chapter.textLength ||
          raw['css'] != publicationCssMode) {
        return null;
      }
      final rows = [
        for (final row in raw['rows'] as List)
          (
            blockId: row[0] as String,
            offset: row[1] as int,
            length: row[2] as int,
            digest: row[3] as String,
          ),
      ];
      var offset = 0, number = 0;
      for (final row in rows) {
        final next = sectionBlockNumber(row.blockId);
        if (row.offset != offset ||
            row.length <= 0 ||
            next <= number ||
            row.digest.length != 64) {
          return null;
        }
        offset += row.length;
        number = next;
      }
      if (rows.isNotEmpty &&
          (rows.length < 2 || offset != chapter.textLength)) {
        return null;
      }
      final anchors = raw['anchors'] as Map;
      return PublicationSectionPlan(
        rows,
        {
          for (final e in anchors.entries)
            e.key as String: (e.value[0] as String, e.value[1] as int),
        },
        (raw['chapterStarts'] as List).cast<String>(),
        (raw['headings'] as Map).cast<String, String>(),
        sourceDigest: sourceDigest,
      );
    } on Object catch (error) {
      if (error is! FormatException &&
          error is! FileSystemException &&
          error is! TypeError &&
          error is! RangeError) {
        rethrow;
      }
      return null;
    }
  }

  ChapterContent read(int index, PublicationSectionRow row) {
    final bytes = _piece(index).readAsBytesSync();
    if (sha256.convert(bytes).toString() != row.digest) {
      throw const FormatException('正文分段缓存不完整');
    }
    final raw = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
    final shared = _sharedData ??=
        (jsonDecode(_shared.readAsStringSync()) as Map).cast<String, Object?>();
    final merged = <String, Object?>{...shared, ...raw};
    merged['displaySource'] = {
      ...(shared['displaySource'] as Map),
      ...(raw['displaySource'] as Map),
    };
    final body = ChapterContent.fromJson(merged);
    if (body.chapterId != chapterId ||
        body.textLength != row.length ||
        body.blocks.firstOrNull?.id != row.blockId) {
      throw const FormatException('正文分段位置与索引不一致');
    }
    return body;
  }

  PublicationSectionPlan write(
    ChapterContent body,
    List<int> cuts,
    Map<String, (String, int)> anchors,
  ) {
    final rows = <PublicationSectionRow>[];
    final source = body.displaySourceJson;
    final headings = declaredPublicationSpreadStarts(body);
    final headingIds = cuts.isEmpty
        ? const <String, String>{}
        : PublicationSectionPlan.headingIds(body);
    if (cuts.isNotEmpty) {
      _write(
        _shared,
        utf8.encode(
          jsonEncode({
            'styles': body.stylesJson,
            'displaySource': {
              for (final key in _sharedKeys)
                if (source!.containsKey(key)) key: source[key],
            },
          }),
        ),
      );
      var offset = 0;
      for (final part in slicePublication(body, cuts)) {
        final json = part.toJson()..remove('styles');
        (json['displaySource'] as Map).removeWhere(
          (key, _) => _sharedKeys.contains(key),
        );
        final bytes = utf8.encode(jsonEncode(json));
        _write(_piece(rows.length), bytes);
        rows.add((
          blockId: part.blocks.first.id,
          offset: offset,
          length: part.textLength,
          digest: sha256.convert(bytes).toString(),
        ));
        offset += part.textLength;
      }
    }
    _write(
      _manifest,
      utf8.encode(
        jsonEncode({
          'source': sourceDigest,
          'length': body.textLength,
          'css': publicationCssMode,
          'rows': [
            for (final r in rows) [r.blockId, r.offset, r.length, r.digest],
          ],
          'anchors': {
            if (rows.isNotEmpty)
              for (final e in anchors.entries) e.key: [e.value.$1, e.value.$2],
          },
          'chapterStarts': headings,
          'headings': headingIds,
        }),
      ),
    );
    return PublicationSectionPlan(
      rows,
      rows.isEmpty ? const {} : anchors,
      headings,
      headingIds,
      sourceDigest: sourceDigest,
    );
  }

  void _write(File file, List<int> bytes) {
    file.parent.createSync(recursive: true);
    final pending = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}-${++_nonce}.next',
    );
    try {
      pending.writeAsBytesSync(bytes);
      pending.renameSync(file.path);
    } finally {
      if (pending.existsSync()) pending.deleteSync();
    }
  }
}

Map<String, (String, int)> publicationSectionAnchors(
  String html,
  Chapter chapter,
  String archivePath, {
  required Set<String> images,
  required bool legacyMobi,
}) {
  final map = ChapterAnchorMap.parse(
    sanitizedHtml: html,
    resourceHref: archivePath,
    availableImages: images,
    legacyMobi: legacyMobi,
    bookId: '',
    contentVersion: kContentVersion,
    chapterId: chapter.id,
  );
  final anchors = {
    for (final element in map.document.querySelectorAll('[id], a[name]'))
      element.attributes['id'] ?? element.attributes['name'] ?? '',
  }..remove('');
  final result = <String, (String, int)>{};
  for (final anchor in anchors) {
    if (map.locatorOfAnchor(anchor) case final point?) {
      result[anchor] = (point.blockId, point.utf16Offset);
    }
  }
  return result;
}
