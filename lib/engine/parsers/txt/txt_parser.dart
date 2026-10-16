/// TXT 解析适配器：按原编码读取正文，切成章节与段落块。
///
/// 输出与 EPUB 完全相同的 [BookDocument]（设计文档 6.1/6.3）：
/// 章节按标题行切分，标题行本身不再重复进正文（章节标题由阅读器顶部显示）；
/// 找不到可靠标题行时按受控大小生成「第 N 节」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/errors/import_error.dart';
import '../../../core/diagnostics/import_timing.dart';
import '../../../core/io/source_fingerprint.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/models/source_content_index.dart';
import '../../../domain/models/locator.dart';
import '../../../domain/services/book_parser.dart';
import '../../normalization/text_normalizer.dart';
import '../../normalization/source_position_matcher.dart';
import 'txt_chapter_rule.dart';
import 'txt_source_lines.dart';

class TxtParser {
  const TxtParser({this.sourceLinesFactory});

  /// 性能对照可注入字节扫描实现，章节规则、分节与编号继续使用同一份代码。
  final TxtSourceLines Function(String, String, String?)? sourceLinesFactory;

  /// 无可靠目录时每节的目标字符数（按段落边界切分，不会切断段落）。
  static const int fallbackSectionChars = 8000;

  /// 分段数量护栏：极端输入不至于生成几万个章节文件。
  static const int maxChapters = 20000;

  /// 没有标题行时，正文开头部分归入的章节名
  static const String prefaceTitle = '卷首';

  Future<BookDocument> parse(
    ParseRequest request, {
    required ParseProgress onProgress,
    required bool Function() isCancelled,
  }) async {
    final timing = traceImportPerf ? ImportTiming('txt_parser') : null;
    final textPath = request.textPath;
    if (textPath == null) {
      throw const ImportFailure(ImportErrorCode.decodeFailed, '缺少正文文本');
    }
    final rule = TxtChapterRule(customPattern: request.txt?.chapterPattern);
    if (request.txt?.chapterPattern != null &&
        !TxtChapterRule.compileCustom(request.txt!.chapterPattern!)) {
      throw const ImportFailure(ImportErrorCode.decodeFailed, '章节规则不可用');
    }

    final forceSections = request.txt?.forceSectionFallback ?? false;

    var builder = _ChapterBuilder(
      workDir: request.workDir,
      contentVersion: request.contentVersion,
      indexedContent: request.indexedContent,
      anchors: request.locationAnchors,
    );
    var useHeadings = false;
    var headingCount = 0;
    var section = 1;
    var started = false;
    var pendingVolume = false;
    builder.startChapter(_sectionTitle(section));

    void addSectionLine(TxtSourceLine sourceLine) {
      final line = sourceLine.text;
      if (isBlankLine(line)) return;
      builder.addParagraph(
        sourceLine.normalizedText ?? normalizeParagraph(line),
        sourceLine,
      );
      if (builder.currentTextLength >= fallbackSectionChars &&
          builder.chapters.length < maxChapters) {
        builder.closeChapter();
        builder.startChapter(_sectionTitle(++section));
      }
    }

    void addHeadingLine(TxtSourceLine sourceLine) {
      final line = sourceLine.text;
      final heading = rule.matchLine(line, 0);
      if (heading != null) {
        builder.closeChapter();
        if (heading.kind == TxtHeadingKind.volume) {
          builder.startVolume(heading.title);
          pendingVolume = true;
        } else {
          builder.startChapter(heading.title);
          pendingVolume = false;
          started = true;
        }
      } else if (!isBlankLine(line)) {
        if (!builder.hasOpenChapter && (!started || pendingVolume)) {
          builder.startChapter(prefaceTitle);
          started = true;
          pendingVolume = false;
        }
        builder.addParagraph(
          sourceLine.normalizedText ?? normalizeParagraph(line),
          sourceLine,
        );
      }
    }

    // 原文件只顺序读取一次。未确定目录时先生成分节候选；第二个章题一到，
    // 只回放此前的短前段并切为按章生成。没有目录的书直接使用分节候选，
    // 不再重读整本。前段超过 64 Ki 字符后落临时文件，不把全书留在内存中。
    final prefix = _TxtPrefix(p.join(request.workDir, '.txt-prefix.tmp'));
    final totalBytes = await File(
      request.indexedContent ? request.sourcePath : textPath,
    ).length();
    var readBytes = 0;
    var lineCount = 0;
    var locationMatches = <String, Locator?>{};
    final sourceLines = request.indexedContent
        ? sourceLinesFactory?.call(
                request.sourcePath,
                request.txt?.charset ?? 'UTF-8',
                textPath,
              ) ??
              TxtSourceLines(
                request.sourcePath,
                request.txt?.charset ?? 'UTF-8',
                preparedPath: textPath,
              )
        : TxtSourceLines(textPath, 'UTF-8');
    timing?.mark('setup');
    try {
      _checkCancelled(isCancelled);
      await for (final batch in sourceLines.readBatches(
        onBytes: (n) => readBytes += n,
      )) {
        for (final line in batch) {
          if (forceSections) {
            addSectionLine(line);
          } else if (useHeadings) {
            addHeadingLine(line);
          } else {
            prefix.add(line);
            addSectionLine(line);
            if (rule.matchLine(line.text, lineCount)?.kind ==
                TxtHeadingKind.chapter) {
              headingCount++;
            }
            if (headingCount == 2) {
              useHeadings = true;
              builder.discard();
              builder = _ChapterBuilder(
                workDir: request.workDir,
                contentVersion: request.contentVersion,
                indexedContent: request.indexedContent,
                anchors: request.locationAnchors,
              );
              var replayed = 0;
              await for (final previous in prefix.lines()) {
                addHeadingLine(previous);
                if (++replayed % 2048 == 0) _checkCancelled(isCancelled);
              }
              prefix.dispose();
            }
          }
          if (++lineCount % 2048 == 0) {
            onProgress(totalBytes == 0 ? null : 0.95 * readBytes / totalBytes);
            _checkCancelled(isCancelled);
          }
        }
      }
      _checkCancelled(isCancelled);
      builder.closeChapter();
      locationMatches = builder.matches.finish();
    } finally {
      prefix.dispose();
    }
    timing?.mark('scan_decode_hash_headings');

    if (builder.chapters.isEmpty) {
      throw const ImportFailure(ImportErrorCode.emptyContent);
    }

    final meta = _splitName(request.displayName);
    timing?.report(
      counts: {
        'sourceBytes': totalBytes,
        'lines': lineCount,
        'chapters': builder.chapters.length,
      },
    );
    onProgress(1);
    return BookDocument(
      title: meta.title,
      author: meta.author,
      contentVersion: request.contentVersion,
      chapters: builder.chapters,
      toc: builder.toc,
      encoding: request.txt?.charset ?? '',
      tocRevision: kTocRevision,
      locationMatches: locationMatches,
      sourceIndex: !request.indexedContent
          ? null
          : SourceContentIndex(
              format: 'txt',
              sourceDigest: sourceLines.digest,
              sourceBytes: sourceLines.byteCount,
              sourceStamp: sourceFingerprint(
                await File(request.sourcePath).stat(),
              ),
              charset: request.txt?.charset ?? 'UTF-8',
              chapters: builder.ranges,
            ),
      warnings: useHeadings ? const [] : const ['未识别到章节标题，已按固定长度分成小节'],
    );
  }

  static void _checkCancelled(bool Function() isCancelled) {
    if (isCancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
  }

  static String _sectionTitle(int index) => '第 $index 节';

  /// 从文件名推断书名与作者：`《书名》作者：某某.txt`。
  ///
  /// 书名就是**文件名本身**（去掉扩展名，书名号、括号、版本说明全部原样保留），
  /// 与 EPUB 同一个口径（设计文档 6.2：文件名是用户自己给的那份，更可控）。
  /// 不做清洗是有教训的：之前那套「去掉开头一个开括号 + 结尾一个闭括号」的规则
  /// 把 `《修真界败类》（校对版全本）` 削成了 `修真界败类》（校对版全本`，
  /// 书架上就出现一个落单的 `》`（用户实测）。
  ///
  /// 作者仍从名字里的 `作者：某某` 取（书架上单独一行显示），取不到就留空。
  static _NameMeta _splitName(String fileName) {
    final full = p.basenameWithoutExtension(fileName).trim();
    final marker = full.indexOf(RegExp(r'作者[:：]'));
    if (marker < 0) return _NameMeta(title: full, author: '');
    final author = full
        .substring(marker)
        .replaceFirst(RegExp(r'^作者[:：]\s*'), '')
        .trim();
    final title = full.substring(0, marker).trim();
    // 「作者：某某.txt」这种极端命名：书名留空没有意义，退回完整文件名
    return _NameMeta(title: title.isEmpty ? full : title, author: author);
  }
}

class _NameMeta {
  const _NameMeta({required this.title, required this.author});
  final String title;
  final String author;
}

/// 按章收集块、写章节文件、组装目录。
class _ChapterBuilder {
  _ChapterBuilder({
    required this.workDir,
    required this.contentVersion,
    required this.indexedContent,
    required List<Locator> anchors,
  }) : matches = SourcePositionMatcher(anchors);

  final String workDir;
  final int contentVersion;
  final bool indexedContent;
  final SourcePositionMatcher matches;
  final ranges = <String, List<Object>>{};
  int _start = 0, _end = 0;

  final List<Chapter> chapters = [];
  final List<TocNode> toc = [];
  List<TocNode>? _volumeChildren;
  final List<ContentBlock> _blocks = [];
  int _blockSeq = 0;
  String? _openTitle;
  int _currentTextLength = 0;

  bool get hasOpenChapter => _openTitle != null && _blockSeq > 0;

  int get currentTextLength => _currentTextLength;

  void startVolume(String title) {
    _volumeChildren = [];
    toc.add(TocNode(title: title, children: _volumeChildren!));
  }

  void startChapter(String title) {
    _openTitle = title;
    _blocks.clear();
    _blockSeq = 0;
    _currentTextLength = 0;
  }

  void addParagraph(String text, TxtSourceLine sourceLine) {
    if (text.isEmpty) return;
    if (_blockSeq == 0) _start = sourceLine.start;
    _end = sourceLine.end;
    _blockSeq++;
    // 来源索引只需要字节边界和精确字符数，正文对象留到实际读章时创建。
    // 段间的一个位置权重与 ContentBlock.textLength 保持一致。
    _currentTextLength += text.length + 1;
    if (!indexedContent || !matches.isEmpty) {
      _blocks.add(
        ContentBlock(
          id: 'b$_blockSeq',
          kind: BlockKind.paragraph,
          runs: [TextRun(text)],
        ),
      );
      if (indexedContent && _blocks.length >= 128) _feedMatches();
    }
  }

  /// 结束当前章：写正文文件并登记章节与目录条目。
  void closeChapter() {
    final title = _openTitle;
    if (title == null || _blockSeq == 0) {
      _openTitle = null;
      _blocks.clear();
      return;
    }
    final id = 'ch${(chapters.length + 1).toString().padLeft(4, '0')}';
    final contentPath = 'content/$contentVersion/$id.json';
    _feedMatches();
    if (indexedContent) {
      ranges[id] = [_start, _end];
    } else {
      final content = ChapterContent(chapterId: id, blocks: List.of(_blocks));
      File(p.join(workDir, '$id.json'))
          .writeAsBytesSync(content.encode(), flush: false);
    }
    chapters.add(
      Chapter(
        id: id,
        ordinal: chapters.length,
        title: title,
        contentPath: contentPath,
        textLength: _currentTextLength,
      ),
    );
    _appendToc(title, id);
    _openTitle = null;
    _blocks.clear();
    _currentTextLength = 0;
  }

  /// 有卷分组时章节挂到最近的卷下，否则平铺。
  void _appendToc(String title, String chapterId) {
    final node = TocNode(title: title, chapterId: chapterId);
    // 解析结束前目录不发布，直接追加即可，无需逐章复制整卷已有条目。
    (_volumeChildren ?? toc).add(node);
  }

  void discard() {
    if (indexedContent) return;
    for (final chapter in chapters) {
      File(p.join(workDir, '${chapter.id}.json')).deleteSync();
    }
  }

  void _feedMatches() {
    if (matches.isEmpty || _blocks.isEmpty) return;
    final id = 'ch${(chapters.length + 1).toString().padLeft(4, '0')}';
    matches.add(id, _blocks);
    if (indexedContent) _blocks.clear();
  }
}

/// 未确定切章方式时保留原始行；内存和磁盘都只缓存第二个章题前的部分。
class _TxtPrefix {
  _TxtPrefix(this.path);
  final String path;
  final _buffer = <TxtSourceLine>[];
  int _characters = 0;
  RandomAccessFile? _output;
  bool _spilled = false;

  void add(TxtSourceLine line) {
    _buffer.add(line);
    _characters += line.text.length + 1;
    if (_characters >= 64 * 1024) {
      _output ??= File(path).openSync(mode: FileMode.writeOnly);
      _spilled = true;
      _flush();
    }
  }

  void _flush() {
    if (_buffer.isEmpty) return;
    _output!.writeStringSync(
      '${_buffer.map((line) => jsonEncode([line.text, line.start, line.end, line.normalizedText])).join('\n')}\n',
    );
    _buffer.clear();
    _characters = 0;
  }

  Stream<TxtSourceLine> lines() async* {
    if (!_spilled) {
      yield* Stream.fromIterable(_buffer);
    } else {
      _flush();
      _output!.closeSync();
      _output = null;
      yield* File(path)
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((line) {
            final values = jsonDecode(line) as List;
            return TxtSourceLine(
              values[0] as String,
              values[1] as int,
              values[2] as int,
              normalizedText: values[3] as String?,
            );
          });
    }
  }

  void dispose() {
    _output?.closeSync();
    _output = null;
    _buffer.clear();
    if (_spilled && File(path).existsSync()) File(path).deleteSync();
  }
}
