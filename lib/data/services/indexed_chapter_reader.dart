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
import '../../core/io/source_fingerprint.dart';

/// 在后台 isolate 中长期持有一本书的索引和 ZIP 句柄，不重复读 OPF 和清单。
class IndexedChapterReader {
  IndexedChapterReader._(
    this.index,
    this.source,
    this.signature,
    this.verification,
  );
  final SourceContentIndex index;
  final File source;
  final String signature;
  final SourceVerificationRecord verification;
  EpubArchive? _archive;
  FileStat? _verified;

  static IndexedChapterReader open(
    String bookDirectory,
    String contentDirectory,
  ) {
    final manifest = jsonDecode(
      File(p.join(contentDirectory, 'manifest.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    final index = SourceContentIndex.fromJson(
      manifest['sourceIndex'] as Map<String, dynamic>,
    );
    if (manifest['contentVersion'] != kContentVersion) {
      throw const FormatException('正文版本与解析规则不一致');
    }
    return IndexedChapterReader._(
      index,
      File(bookSourcePath(bookDirectory, index.format)),
      sha256.convert(utf8.encode(jsonEncode(index.toJson()))).toString(),
      SourceVerificationRecord(contentDirectory),
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
    final ChapterContent content;
    if (index.format == 'epub') {
      final archive = _archive ??= EpubArchive.open(source.path);
      archive.resetTotalBudget();
      final path = location.single as String;
      final parsed = XhtmlBlockBuilder(
        basePath: path,
        buildTextMap: false,
        resolveImage: (entry) {
          final size = index.images[entry];
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
    if (content.textLength != chapter.textLength) {
      throw const ContentFailure(ContentErrorCode.corrupted, '正文长度与章节索引不一致');
    }
    await verifySource();
    return content;
  }

  void close() => _archive?.close();
}
