import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/io/source_digest.dart';

import 'package:path/path.dart' as p;
import 'package:direct_read_rust/direct_read_rust.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/source_content_index.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/normalization/text_normalizer.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/xhtml_blocks.dart';
import '../../engine/parsers/epub/image_sniff.dart';
import '../../engine/parsers/txt/txt_text_preparer.dart';
import 'book_source_path.dart';
import 'source_verification_record.dart';
import '../../engine/parsers/pdf/pdf_file.dart';
import '../../engine/parsers/pdf/pdf_page_pictures.dart';
import 'indexed_publication.dart';
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
      );
    } else {
      final start = location[0] as int, end = location[1] as int;
      final handle = source.openSync();
      final Uint8List bytes;
      try {
        handle.setPositionSync(start);
        bytes = handle.readSync(end - start);
      } finally {
        handle.closeSync();
      }
      final scan = NativeTxtStream(
        charset: index.charset,
        // 直接解码原字节，BOM 只在整本开头移除，章内保留。
        offset: start,
      );
      final List<NativeTxtLine> lines;
      try {
        lines = scan.feed(bytes, finish: true);
      } finally {
        scan.close();
      }
      final blocks = <ContentBlock>[];
      for (final line in lines) {
        if (isBlankLine(line.text)) continue;
        final normalized = line.normalized;
        if (normalized.isEmpty) continue;
        blocks.add(
          ContentBlock(
            id: 'b${blocks.length + 1}',
            kind: BlockKind.paragraph,
            runs: [TextRun(normalized)],
          ),
        );
      }
      content = ChapterContent(chapterId: chapter.id, blocks: blocks);
    }
    // PDF补入的图片使用自己的块ID，不改变已有文字；图片块会增加分隔计数。
    if (index.format != 'pdf' && content.textLength != chapter.textLength) {
      throw const ContentFailure(ContentErrorCode.corrupted, '正文长度与章节索引不一致');
    }
    await verifySource();
    return content;
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
    for (final block in content.blocks) {
      final path = block.resourcePath;
      if (path == null || !path.startsWith('res/')) continue;
      final entry = path.substring(4);
      if (!index.images.containsKey(entry)) continue;
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
