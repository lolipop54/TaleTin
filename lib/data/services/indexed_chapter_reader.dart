import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../../core/io/source_digest.dart';

import 'package:path/path.dart' as p;
import 'package:direct_read_rust/direct_read_rust.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/source_content_index.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../domain/services/txt_chapter_sections.dart';
import '../../engine/normalization/text_normalizer.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/xhtml_blocks.dart';
import '../../engine/styles/chapter_styler.dart';
import '../../engine/layout/book_background.dart';
import '../../engine/parsers/epub/image_sniff.dart';
import '../../engine/parsers/txt/txt_text_preparer.dart';
import 'book_source_path.dart';
import 'source_verification_record.dart';
import '../../engine/parsers/pdf/pdf_file.dart';
import '../../engine/parsers/pdf/pdf_page_pictures.dart';
import 'indexed_publication.dart';
import 'inline_image_index_compatibility.dart';
import 'publication_cache.dart';
import '../../core/io/source_fingerprint.dart';

/// 在后台 isolate 中长期持有一本书的索引和 ZIP 句柄，不重复读 OPF 和清单。
class IndexedChapterReader {
  IndexedChapterReader._(
    this.index,
    this.source,
    this.signature,
    this.verification,
    this.cache,
  );
  final SourceContentIndex index;
  final File source;
  final String signature;
  final SourceVerificationRecord verification;
  final PublicationCache? cache;
  late final _persistentImages = index.images.entries
      .where((entry) => entry.value[0] >= 0)
      .map((entry) => entry.key)
      .toSet();
  EpubArchive? _archive;
  Future<PdfFile>? _pdf;
  FileStat? _verified;
  final _txtSectionStarts = <String, List<TxtSectionStart>>{};

  /// 导出证明必须使用核验过的同一次状态，不能重新stat后把新文件误标为已核验。
  FileStat? get verifiedStat => _verified;

  static IndexedChapterReader open(
    String bookDirectory,
    String contentDirectory, {
    String? cacheRoot,
    String? cacheEpoch,
    (int, SourceContentIndex)? preparedIndex,
  }) {
    // 仓库已解析过时直接接收同一份快照；后台独立使用者仍可自行读取清单。
    final Map<String, dynamic>? manifest = preparedIndex == null
        ? jsonDecode(
            File(p.join(contentDirectory, 'manifest.json')).readAsStringSync(),
          ) as Map<String, dynamic>
        : null;
    final index =
        preparedIndex?.$2 ??
        SourceContentIndex.fromJson(
          manifest!['sourceIndex'] as Map<String, dynamic>,
        );
    if ((preparedIndex?.$1 ?? manifest!['contentVersion']) != kContentVersion) {
      throw const FormatException('正文版本与解析规则不一致');
    }
    return IndexedChapterReader._(
      index,
      File(bookSourcePath(bookDirectory, index.format)),
      sha256.convert(utf8.encode(jsonEncode(index.toJson()))).toString(),
      SourceVerificationRecord(contentDirectory),
      PublicationCache(
        PublicationCache.effectiveRoot(p.dirname(bookDirectory), cacheRoot),
        p.basename(bookDirectory),
        index.sourceDigest,
        epoch: cacheEpoch,
      ),
    );
  }

  /// 首次使用核对全部源字节；之后每次读取检查文件属性，变化时重新核对摘要。
  /// 缓存命中也要检查，避免原路径已换书却继续显示旧章、保存错误位置。
  Future<void> verifySource() async {
    final stat = source.statSync();
    if (stat.type != FileSystemEntityType.file) {
      throw ContentFailure(ContentErrorCode.missing, source.path);
    }
    if (_verified?.size == stat.size &&
        _verified?.modified == stat.modified &&
        _verified?.changed == stat.changed) {
      return;
    }
    _archive?.close();
    _archive = null;
    _verified = null;
    if (stat.size == index.sourceBytes &&
        (index.sourceStamp == sourceFingerprint(stat) ||
            verification.matches(index.sourceDigest, stat))) {
      _verified = stat;
      return;
    }
    if (stat.size != index.sourceBytes ||
        await sourceFileDigest(source.path) != index.sourceDigest) {
      throw const ContentFailure(
        ContentErrorCode.sourceChanged,
        '原文件已改变，与导入时的正文不一致',
      );
    }
    final after = source.statSync();
    if (sourceFingerprint(after) != sourceFingerprint(stat)) {
      throw const ContentFailure(ContentErrorCode.sourceChanged, '源文件在核验期间改变');
    }
    verification.save(index.sourceDigest, stat);
    _verified = stat;
  }

  final _cssTexts = <String, String?>{};

  /// 章节引用的样式文件：按归档条目读原始文本，解析交给 Rust 统一 CSS。
  String? _cssText(String path) {
    if (_cssTexts.containsKey(path)) return _cssTexts[path];
    final archive = _archive;
    if (archive == null) return null;
    try {
      if (!archive.contains(path)) return _cssTexts[path] = null;
      return _cssTexts[path] = utf8.decode(
        archive.readBytes(path),
        allowMalformed: true,
      );
    } on Object {
      return _cssTexts[path] = null;
    }
  }

  Future<ChapterContent> read(
    Chapter chapter,
    DecodeBytes decodeBytes, {
    bool textOnly = false,
  }) async {
    final location = index.chapters[chapter.id];
    if (location == null) throw const FormatException('缺少章节来源索引');
    ChapterContent content;
    if (index.format == 'pdf') {
      content = ChapterContent.fromJson(
        (jsonDecode(
          File(p.join(verification.file.parent.path, '${chapter.id}.json'))
              .readAsStringSync(),
        ) as Map).cast<String, Object?>(),
      );
      if (content.textLength != chapter.textLength) {
        throw const ContentFailure(
          ContentErrorCode.corrupted,
          'PDF文字长度与章节索引不一致',
        );
      }
      if (!textOnly && content.pdfPage!.pendingPictures) {
        final pdf = await (_pdf ??= PdfFile.open(source.path));
        content = await preparePdfPagePictures(pdf, content);
      }
    } else if (index.format != 'txt') {
      final archive = _archive ??= openIndexedPublication(
        source.path,
        verification.file.parent.path,
        index,
      );
      archive.resetTotalBudget();
      final path = location.single as String;
      final parsed = XhtmlBlockBuilder(
        basePath: path,
        buildTextMap: false,
        styleTextResolver: _cssText,
        resolveImage: (entry) {
          final size = index.images[entry];
          if (cache != null && size != null) {
            if (!textOnly) return _prepareImage(entry);
            return ResolvedImage(
              resourcePath: 'res/$entry',
              width: size[0] < 0 ? 0 : size[0],
              height: size[1] < 0 ? 0 : size[1],
            );
          }
          if (size != null && size[0] < 0) {
            if (textOnly) {
              return ResolvedImage(
                resourcePath: 'res/$entry',
                width: 0,
                height: 0,
              );
            }
            final bytes = archive.readBytes(entry);
            final resolved = sniffImageSize(bytes);
            // 正文根目录在 open 时保存，外部源文件旁边不写任何产物。
            final resource = File(
              p.join(verification.file.parent.path, 'res', entry),
            );
            resource.parent.createSync(recursive: true);
            resource.writeAsBytesSync(bytes, flush: false);
            index.images[entry] = [resolved.width, resolved.height];
            return ResolvedImage(
              resourcePath: 'res/$entry',
              width: resolved.width,
              height: resolved.height,
            );
          }
          return size == null
              ? null
              : ResolvedImage(
                  resourcePath: 'res/$entry',
                  width: size[0],
                  height: size[1],
                );
        },
      ).convertBytes(archive.readBytes(path));
      content = ChapterContent(
        chapterId: chapter.id,
        blocks: parsed.blocks,
        tables: parsed.tables,
        epubDetailsRevision: kEpubDetailsRevision,
        // Rust 转换时已经算好样式表与编号，直接带上；Dart 不用再补。
        stylesJson: parsed.stylesJson,
        displaySourceJson: parsed.displaySourceJson,
      );
    } else {
      return readTxt(chapter);
    }
    if (index.format != 'txt' && index.format != 'pdf') {
      content = matchInlineImageIndex(content, chapter.textLength);
    }
    // PDF补入的图片使用自己的块ID，不改变已有文字；图片块会增加分隔计数。
    if (index.format != 'pdf' && content.textLength != chapter.textLength) {
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '正文长度与章节索引不一致（正文 ${content.textLength}，索引 ${chapter.textLength}）',
      );
    }
    await verifySource();
    // 批次 F：给正文挂上样式表与 styleId，然后丢掉旧显示字段——ContentBlock 的样式字段
    // 只作为「建表原料」在解析阶段存在，读出后的正文只有样式表与 sid。
    // 批次 F：挂上样式表与 styleId 后丢掉旧显示字段；块上的样式字段只在解析阶段
    // 作为「建表原料」存在，读出后的正文只有样式表与 `sid`。
    return ChapterStyler.toStylesOnly(ChapterStyler.apply(content));
  }

  Future<ChapterContent> readTxt(Chapter chapter) async {
    final location = index.chapters[chapter.id];
    if (location == null) throw const FormatException('缺少章节来源索引');
    final content = buildTxtContent(chapter, _txtParagraphs(location));
    await verifySource();
    return content;
  }

  static ChapterContent buildTxtContent(
    Chapter chapter,
    Iterable<String> paragraphs, {
    int firstParagraph = 0,
    int? expectedLength,
  }) {
    final blocks = <ContentBlock>[];
    var length = 0;
    for (final text in paragraphs) {
      length += text.length + 1;
      blocks.add(
        ContentBlock(
          id: 'b${firstParagraph + blocks.length + 1}',
          kind: BlockKind.paragraph,
          runs: [TextRun(text)],
        ),
      );
    }
    final expected = expectedLength ?? chapter.textLength;
    if (length != expected) {
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '正文长度与索引不一致（正文 $length，索引 $expected）',
      );
    }
    return ChapterContent(
      chapterId: chapter.id,
      blocks: blocks,
      stylesJson: ChapterStyler.emptyTableJson,
    );
  }

  /// 已导入的小节可以直接显示。缺少或无法使用的索引回到原有扫描。
  List<TxtTocSection>? indexedTxtTocSections(Chapter chapter) {
    final starts = index.txtSectionStarts[chapter.id];
    return _validTxtStarts(chapter, starts) ? txtTocOfStarts(starts!) : null;
  }

  static List<TxtTocSection> txtTocOfStarts(List<TxtSectionStart> starts) => [
    if (starts.length > 1)
      for (final start in starts)
        (blockId: 'b${start.paragraph + 1}', offset: start.textOffset),
  ];

  bool _validTxtStarts(Chapter chapter, List<TxtSectionStart>? starts) {
    final range = index.chapters[chapter.id];
    if (starts == null ||
        starts.isEmpty ||
        range == null ||
        starts.first !=
            (byteOffset: range[0] as int, paragraph: 0, textOffset: 0)) {
      return false;
    }
    var previous = starts.first;
    final end = range[1] as int;
    for (var i = 1; i < starts.length; i++) {
      final start = starts[i];
      if (start.byteOffset <= previous.byteOffset ||
          start.byteOffset >= end ||
          start.paragraph <= previous.paragraph ||
          start.textOffset <
              TxtChapterSections.nextStartAfter(previous.textOffset) ||
          start.textOffset >= chapter.textLength) {
        return false;
      }
      previous = start;
    }
    return true;
  }

  /// 旧书从现有章节范围补出小节索引，缓存仅随同一份来源使用。
  Future<List<TxtSectionStart>> loadTxtSectionStarts(Chapter chapter) async {
    await verifySource();
    final cached = _txtSectionStarts[chapter.id];
    if (cached != null) return cached;
    final imported = index.txtSectionStarts[chapter.id];
    if (_validTxtStarts(chapter, imported)) {
      return _txtSectionStarts[chapter.id] = imported!;
    }
    final store = cache!;
    final file = store.file('txt-sections1/$signature/${chapter.id}.json');
    try {
      final saved = decodeTxtSectionStarts(jsonDecode(file.readAsStringSync()));
      if (_validTxtStarts(chapter, saved)) {
        return _txtSectionStarts[chapter.id] = saved!;
      }
    } on FileSystemException {
      // 可重建缓存尚未生成，继续读取原文件。
    } on FormatException {
      // 写盘中断时重建。
    }
    final range = index.chapters[chapter.id]!;
    final starts = <TxtSectionStart>[];
    var paragraph = 0, length = 0, nextOffset = 0;
    for (final (text, byteOffset) in _scanTxtParagraphs(
      range[0] as int,
      range[1] as int,
      (text, byteOffset) => (text, byteOffset),
    )) {
      if (length >= nextOffset) {
        starts.add((
          byteOffset: byteOffset,
          paragraph: paragraph,
          textOffset: length,
        ));
        nextOffset = TxtChapterSections.nextStartAfter(length);
      }
      length += text.length + 1;
      paragraph++;
    }
    if (length != chapter.textLength || !_validTxtStarts(chapter, starts)) {
      throw const ContentFailure(ContentErrorCode.corrupted, '分节字数与章节索引不一致');
    }
    await verifySource();
    try {
      await store.beginPreparation();
      try {
        store.write(
          file,
          utf8.encode(jsonEncode(encodeTxtSectionStarts(starts))),
        );
        store.trim();
      } finally {
        store.endPreparation();
      }
    } on FileSystemException {
      // 失败只影响下次重建，当前读取继续使用内存里的索引。
    }
    return _txtSectionStarts[chapter.id] = starts;
  }

  Future<ChapterContent> readTxtSection(
    Chapter chapter,
    List<TxtSectionStart> starts,
    int section,
  ) async {
    await verifySource();
    final first = starts[section];
    final next = section + 1 < starts.length ? starts[section + 1] : null;
    final end = next?.byteOffset ?? index.chapters[chapter.id]!.last as int;
    final content = buildTxtContent(
      chapter,
      _scanTxtParagraphs(first.byteOffset, end, (text, _) => text),
      firstParagraph: first.paragraph,
      expectedLength:
          (next?.textOffset ?? chapter.textLength) - first.textOffset,
    );
    if (next != null &&
        first.paragraph + content.blocks.length != next.paragraph) {
      throw const ContentFailure(ContentErrorCode.corrupted, '小节段落数与索引不一致');
    }
    await verifySource();
    return content;
  }

  ({List<TxtTocSection> sections, List<String>? paragraphs}) txtTocSections(
    Chapter chapter, {
    int cacheParagraphs = 0,
  }) {
    final location = index.chapters[chapter.id];
    if (location == null) throw const FormatException('缺少章节来源索引');
    var paragraphs = cacheParagraphs == 0 ? null : <String>[];
    final sections = TxtChapterSections(
      _txtParagraphs(location).map((text) {
        final kept = paragraphs;
        if (kept != null) {
          if (kept.length == cacheParagraphs) {
            paragraphs = null;
          } else {
            kept.add(text);
          }
        }
        return text.length + 1;
      }),
    );
    if (sections.textLength != chapter.textLength) {
      throw const ContentFailure(ContentErrorCode.corrupted, '分节字数与章节索引不一致');
    }
    return (
      sections: [
        if (sections.starts.length > 1)
          for (final start in sections.starts)
            (blockId: 'b${start.paragraph + 1}', offset: start.offset),
      ],
      paragraphs: paragraphs,
    );
  }

  /// 正文和小节目录按同样的原字节、编码和段落规范化规则读取。
  Iterable<String> _txtParagraphs(List<Object> location) => _scanTxtParagraphs(
    location[0] as int,
    location[1] as int,
    (text, _) => text,
  );

  Iterable<T> _scanTxtParagraphs<T>(
    int start,
    int end,
    T Function(String, int) convert,
  ) sync* {
    final scan = NativeTxtStream(charset: index.charset, offset: start);
    RandomAccessFile? handle;
    try {
      handle = source.openSync();
      handle.setPositionSync(start);
      var remaining = end - start;
      while (remaining > 0) {
        final bytes = handle.readSync(math.min(remaining, 256 * 1024));
        remaining -= bytes.length;
        final done = remaining == 0 || bytes.isEmpty;
        yield* scan.feedParagraphRanges(
          bytes,
          isBlankLine: isBlankLine,
          finish: done,
          convert: convert,
        );
        if (done) break;
      }
    } finally {
      scan.close();
      handle?.closeSync();
    }
  }

  ResolvedImage _prepareImage(String entry) {
    // Capture the persistent cover set before this worker updates dimensions.
    final persistent = _persistentImages.contains(entry);
    final file = persistent
        ? File(p.join(verification.file.parent.path, 'res', entry))
        : cache!.file(p.join('assets', entry));
    var size = index.images[entry]!;
    if (!persistent && !file.existsSync()) {
      cache!.adopt(
        File(p.join(verification.file.parent.path, 'res', entry)),
        file,
      );
    }
    if (!file.existsSync()) {
      final archive = _archive ??= openIndexedPublication(
        source.path,
        verification.file.parent.path,
        index,
      );
      final bytes = archive.readBytes(entry);
      if (persistent) {
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
      } else {
        cache!.write(file, bytes);
      }
      final dimensions = sniffImageSize(bytes);
      size = index.images[entry] = [dimensions.width, dimensions.height];
    } else if (size[0] < 0) {
      final dimensions = sniffImageSize(file.readAsBytesSync());
      size = index.images[entry] = [dimensions.width, dimensions.height];
    }
    return ResolvedImage(
      resourcePath: 'res/$entry',
      width: size[0],
      height: size[1],
    );
  }

  /// Cached body JSON does not prove that its images survived cache eviction.
  /// Prepare and pin them again before the chapter is delivered to the view.
  Future<void> prepareResources(ChapterContent content) async {
    final store = cache;
    if (store == null) return;
    if (index.format == 'pdf') {
      final files = <File>[];
      for (final block in content.blocks) {
        final path = block.resourcePath;
        if (path == null) continue;
        final target = store.file(p.join('assets', path.substring(4)));
        if (!target.existsSync()) {
          final pdf = await (_pdf ??= PdfFile.open(source.path));
          final info = content.pdfPage!;
          final box = info.blocks[block.id]!;
          // 限制单张图片像素量，长页面不因极端宽高比占满内存。
          final width = (1600 * box[2]).round().clamp(200, 1600);
          store.write(target, await pdf.render(info.index, width, box: box));
        }
        files.add(target);
      }
      store.pin(content.chapterId, files);
      store.trim();
      return;
    }
    final files = <File>[store.file('chapters/${content.chapterId}.json')];
    for (final path in chapterImageResources(content)) {
      if (!path.startsWith('res/')) continue;
      final entry = path.substring(4);
      if (!index.images.containsKey(entry)) {
        // 有些 EPUB 的 CSS 图片漏列在 OPF 中，只接受归档内真实图片条目。
        final archive = _archive ??= openIndexedPublication(
          source.path,
          verification.file.parent.path,
          index,
        );
        if (!{
              '.png',
              '.jpg',
              '.jpeg',
              '.gif',
              '.webp',
              '.bmp',
              '.svg',
            }.contains(p.extension(entry).toLowerCase()) ||
            !archive.contains(entry)) {
          continue;
        }
        index.images[entry] = [-1, -1];
      }
      _prepareImage(entry);
      if (!_persistentImages.contains(entry)) {
        files.add(store.file(p.join('assets', entry)));
      }
    }
    store.pin(content.chapterId, files);
    store.trim();
  }

  Future<void> close() async {
    _archive?.close();
    if (_pdf != null) await (await _pdf!).close();
    cache?.close();
  }
}
