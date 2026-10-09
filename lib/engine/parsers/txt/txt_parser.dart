/// TXT 解析适配器：把已转成 UTF-8 的正文文本切成章节与段落块。
///
/// 输出与 EPUB 完全相同的 [BookDocument]（设计文档 6.1/6.3）：
/// 章节按标题行切分，标题行本身不再重复进正文（章节标题由阅读器顶部显示）；
/// 找不到可靠标题行时按受控大小生成「第 N 节」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/errors/import_error.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/services/book_parser.dart';
import '../../normalization/text_normalizer.dart';
import 'txt_chapter_rule.dart';

class TxtParser {
  const TxtParser();

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

    // 第一遍：找出所有标题行，判断目录是否可靠（强制分段时跳过这一遍）
    final headings = <TxtHeading>[];
    var lineCount = 0;
    await for (final line in _lines(textPath)) {
      if (forceSections) {
        lineCount++;
        continue;
      }
      final heading = rule.matchLine(line, lineCount);
      if (heading != null) headings.add(heading);
      lineCount++;
      if (lineCount % 4096 == 0) {
        onProgress(0.30 * (lineCount / (lineCount + 4096)).clamp(0.0, 0.99));
        if (isCancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
      }
    }

    final chapterHeadings =
        headings.where((h) => h.kind == TxtHeadingKind.chapter).toList();
    // 只有一两个标题行不足以构成目录，按设计降级为受控分段
    final useHeadings = !forceSections && chapterHeadings.length >= 2;

    final builder = _ChapterBuilder(
      workDir: request.workDir,
      contentVersion: request.contentVersion,
    );

    if (useHeadings) {
      await _buildByHeadings(
        textPath: textPath,
        headings: headings,
        lineCount: lineCount,
        builder: builder,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } else {
      await _buildBySections(
        textPath: textPath,
        lineCount: lineCount,
        builder: builder,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }

    if (builder.chapters.isEmpty) {
      throw const ImportFailure(ImportErrorCode.emptyContent);
    }

    final meta = _splitName(request.displayName);
    onProgress(1);
    return BookDocument(
      title: meta.title,
      author: meta.author,
      contentVersion: request.contentVersion,
      chapters: builder.chapters,
      toc: builder.toc,
      encoding: request.txt?.charset ?? '',
      warnings: useHeadings
          ? const []
          : const ['未识别到章节标题，已按固定长度分成小节'],
    );
  }

  /// 按标题行切分：卷标题进目录分组，章标题开新章。
  Future<void> _buildByHeadings({
    required String textPath,
    required List<TxtHeading> headings,
    required int lineCount,
    required _ChapterBuilder builder,
    required ParseProgress onProgress,
    required bool Function() isCancelled,
  }) async {
    final byLine = {for (final h in headings) h.lineIndex: h};
    var lineIndex = 0;
    var started = false;
    // 卷标题到第一个章标题之间的正文（常见为卷首语）单独成章
    var pendingVolume = false;
    await for (final line in _lines(textPath)) {
      final heading = byLine[lineIndex];
      if (heading != null) {
        if (heading.kind == TxtHeadingKind.volume) {
          builder.closeChapter();
          builder.startVolume(heading.title);
          pendingVolume = true;
        } else {
          builder.closeChapter();
          builder.startChapter(heading.title);
          pendingVolume = false;
          started = true;
        }
      } else if (!isBlankLine(line)) {
        if (!builder.hasOpenChapter) {
          // 正文开头（或卷首）没有章标题时，先归入「卷首」
          if (!started || pendingVolume) {
            builder.startChapter(prefaceTitle);
            started = true;
            pendingVolume = false;
          }
        }
        builder.addParagraph(normalizeParagraph(line));
      }
      lineIndex++;
      if (lineIndex % 2048 == 0) {
        onProgress(0.3 + 0.65 * (lineIndex / (lineCount + 1)));
        if (isCancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
      }
    }
    builder.closeChapter();
  }

  /// 没有可用目录：按目标长度切段，段名「第 N 节」。
  Future<void> _buildBySections({
    required String textPath,
    required int lineCount,
    required _ChapterBuilder builder,
    required ParseProgress onProgress,
    required bool Function() isCancelled,
  }) async {
    var lineIndex = 0;
    var section = 0;
    builder.startChapter(_sectionTitle(++section));
    await for (final line in _lines(textPath)) {
      if (!isBlankLine(line)) {
        builder.addParagraph(normalizeParagraph(line));
        if (builder.currentTextLength >= fallbackSectionChars &&
            builder.chapters.length < maxChapters) {
          builder.closeChapter();
          builder.startChapter(_sectionTitle(++section));
        }
      }
      lineIndex++;
      if (lineIndex % 2048 == 0) {
        onProgress(0.3 + 0.65 * (lineIndex / (lineCount + 1)));
        if (isCancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
      }
    }
    builder.closeChapter();
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

  /// 逐行读取 UTF-8 文本（已由导入流水线转码并去掉 BOM）。
  Stream<String> _lines(String path) => File(path)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
}

class _NameMeta {
  const _NameMeta({required this.title, required this.author});
  final String title;
  final String author;
}

/// 按章收集块、写章节文件、组装目录。
class _ChapterBuilder {
  _ChapterBuilder({required this.workDir, required this.contentVersion});

  final String workDir;
  final int contentVersion;

  final List<Chapter> chapters = [];
  final List<TocNode> toc = [];
  final List<ContentBlock> _blocks = [];
  int _blockSeq = 0;
  String? _openTitle;
  int _currentTextLength = 0;

  bool get hasOpenChapter => _openTitle != null && _blocks.isNotEmpty;

  int get currentTextLength => _currentTextLength;

  void startVolume(String title) {
    toc.add(TocNode(title: title));
  }

  void startChapter(String title) {
    _openTitle = title;
    _blocks.clear();
    _blockSeq = 0;
    _currentTextLength = 0;
  }

  void addParagraph(String text) {
    if (text.isEmpty) return;
    final block = ContentBlock(
      id: 'b${++_blockSeq}',
      kind: BlockKind.paragraph,
      runs: [TextRun(text)],
    );
    _blocks.add(block);
    _currentTextLength += block.textLength;
  }

  /// 结束当前章：写正文文件并登记章节与目录条目。
  void closeChapter() {
    final title = _openTitle;
    if (title == null || _blocks.isEmpty) {
      _openTitle = null;
      _blocks.clear();
      return;
    }
    final id = 'ch${(chapters.length + 1).toString().padLeft(4, '0')}';
    final contentPath = 'content/$contentVersion/$id.json';
    final content = ChapterContent(chapterId: id, blocks: List.of(_blocks));
    File(p.join(workDir, '$id.json'))
        .writeAsBytesSync(content.encode(), flush: false);
    chapters.add(Chapter(
      id: id,
      ordinal: chapters.length,
      title: title,
      contentPath: contentPath,
      textLength: content.textLength,
    ));
    _appendToc(title, id);
    _openTitle = null;
    _blocks.clear();
    _currentTextLength = 0;
  }

  /// 有卷分组时章节挂到最近的卷下，否则平铺。
  void _appendToc(String title, String chapterId) {
    final node = TocNode(title: title, chapterId: chapterId);
    if (toc.isNotEmpty && !toc.last.isLeaf) {
      final last = toc.removeLast();
      toc.add(TocNode(
        title: last.title,
        children: [...last.children, node],
      ));
    } else {
      toc.add(node);
    }
  }
}
