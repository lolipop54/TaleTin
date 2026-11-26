import '../../../domain/models/book_document.dart';
import '../../../domain/models/display_source_index.dart';
import '../../../domain/services/toc_entry_index.dart';
import '../../normalization/locator_mapper.dart' show blockTextOf;
import '../../styles/chapter_styler.dart';
import '../../styles/style_box_value.dart' show PositionSpec;

final _chapterNumber = RegExp(
  r'^(?:第[\d０-９〇零一二三四五六七八九十百千萬万兩两]+[章回]|chapter\b)',
  caseSensitive: false,
);
final _numberedTitle = RegExp(
  r'^(?:第[\d０-９〇零一二三四五六七八九十百千萬万兩两]+[章回](?:$|[\s、：:])|chapter\s+\d+\b)',
  caseSensitive: false,
);
const _chapterDigits = r'[\d０-９〇零一二三四五六七八九十百千萬万兩两]+';
final _prefixedChapterTitle = RegExp(
  '^(?:正文[\\s：:]+|第$_chapterDigits[卷册冊部集][^第]{0,48})'
  '第$_chapterDigits[章回](?:\$|[\\s、：:])',
);
final _frontMatter = RegExp(
  r'^(?:封面|扉页|书名页|版权(?:信息|页)?|目录|插图|注释|脚注|cover|title\s*page|copyright|contents|illustrations|footnotes)$',
  caseSensitive: false,
);
final _spaces = RegExp(r'\s+');
final _kindleSegment = RegExp(r'-s(\d{5,})\.html$');

bool isKindleContinuation(String href) {
  final number = _kindleSegment.firstMatch(href)?.group(1);
  return number != null && number != '00000';
}

String _titleKey(String text) => text.replaceAll(_spaces, '').toLowerCase();

Map<String, List<TocTitleRef>> publicationSpreadTitles(Object? toc) =>
    toc is! List
    ? const {}
    : collectTocTitles([
        for (final node in toc)
          if (node is Map) TocNode.fromJson(node.cast<String, Object?>()),
      ]);

List<String> declaredPublicationSpreadStarts(ChapterContent body) {
  final source = body.displaySourceJson;
  if (source?['coverPage'] == true) return const [];
  final starts = <int>{
    for (final row in source?['spreadChapters'] as List? ?? const [])
      row.first as int,
    ...((source?['tocSpreadStarts'] as List?)?.cast<int>() ?? const []),
  }.toList()..sort();
  return [for (final index in starts) body.blocks[index].id];
}

/// 目录位置只提供章首候选。正文中的独立同名标题负责确认，
/// 正文块号、书签锚点和已有章节 ID 仍来自原转换结果。
ChapterContent withPublicationSpreadChapters(
  ChapterContent content,
  List<TocTitleRef> titles, {
  Map<String, double?>? positions,
  bool continuation = false,
}) {
  final source = content.displaySourceJson;
  if (source?['coverPage'] == true || content.pdfPage != null) {
    return content;
  }
  final ranges = source?['spreadChapters'] as List? ?? const [];
  // Kindle 分段会补回上一段尚未关闭的祖先标签。续段开头的
  // chapter 容器可能是补回的，需再用这一段自己的目录标题核实。
  final explicit = continuation && ranges.any((range) => range.first == 0)
      ? ranges.where((range) => range.first != 0).toList()
      : ranges;
  final saved = (source?['tocSpreadStarts'] as List?)?.cast<int>();
  final confirmed =
      saved ?? _confirmedStarts(content, titles, explicit, positions);
  final starts = _includeOpeningImages(
    content,
    confirmed,
    explicit,
    continuation,
  );
  if ((starts.isEmpty || (saved != null && identical(starts, confirmed))) &&
      identical(explicit, ranges)) {
    return content;
  }
  return ChapterContent(
    chapterId: content.chapterId,
    blocks: content.blocks,
    tables: content.tables,
    epubDetailsRevision: content.epubDetailsRevision,
    pdfPage: content.pdfPage,
    stylesJson: content.stylesJson,
    displaySourceJson: {
      ...?source,
      if (!identical(explicit, ranges)) 'spreadChapters': explicit,
      'tocSpreadStarts': starts,
    },
  );
}

List<int> _includeOpeningImages(
  ChapterContent content,
  List<int> starts,
  List<dynamic> explicit,
  bool continuation,
) {
  if (starts.isEmpty) return starts;
  final blocks = content.blocks;
  final json = content.displaySourceJson;
  DisplaySourceIndex? source;
  var checkedSource = false;
  List<int>? oldPageBreaks;
  bool blank(int i) =>
      blocks[i].kind == BlockKind.paragraph &&
      blocks[i].inlineImages.isEmpty &&
      blocks[i].runLength == 0;

  List<int>? result;
  for (final (position, title) in starts.indexed) {
    final head = blocks[title];
    if (head.kind == BlockKind.paragraph) {
      final text = blockTextOf(head).trim();
      if (!_numberedTitle.hasMatch(text) &&
          !_prefixedChapterTitle.hasMatch(text)) {
        continue;
      }
    } else if (head.kind != BlockKind.heading && head.kind != BlockKind.quote) {
      continue;
    }
    var image = title - 1;
    while (image >= 0 && blank(image)) {
      image--;
    }
    if (image < 0 ||
        (position > 0 && image <= starts[position - 1]) ||
        blocks[image].kind != BlockKind.image ||
        blocks[image].resourcePath == null ||
        blocks[image].resourcePath == json?['coverImage'] ||
        explicit.any((range) => image >= range.first && image <= range.last)) {
      continue;
    }
    var before = image - 1;
    while (before >= 0 && blank(before)) {
      before--;
    }
    if (!checkedSource) {
      source = DisplaySourceIndex.fromJson(json);
      checkedSource = true;
    }
    final imageChain = source?.chainOfBlock(image) ?? const <DisplayElement>[];
    final titleChain = source?.chainOfBlock(title) ?? const <DisplayElement>[];
    final styles = ChapterStyler.layoutTableOf(content);
    if (imageChain.any((e) {
      final position = styles[e.styleId ?? 0].block.position;
      return position == PositionSpec.absolute ||
          position == PositionSpec.fixed;
    })) {
      continue;
    }
    final sharedOpening = titleChain.any(
      (e) =>
          e.firstBlock == image &&
          const {'div', 'section', 'article', 'header'}.contains(e.tag),
    );
    // 合卷里的普通插图可能属于上一章。只有带共同章首容器的图，或正文文件
    // 开头未被明确拆开的独立图，才随已核实的章题开启一组双页。
    if (sharedOpening) {
      (result ??= starts.toList())[position] = image;
      continue;
    }
    if (continuation || before >= 0) continue;
    oldPageBreaks ??= [
      for (final e in source?.elements ?? const <DisplayElement>[])
        if (e.tag == 'mbp:pagebreak') e.anchor,
    ];
    if (imageChain.any(
          (e) =>
              e.lastBlock == image &&
              _forcedPageBreak(styles[e.styleId ?? 0].block.breakAfter),
        ) ||
        titleChain.any(
          (e) =>
              e.firstBlock == title &&
              _forcedPageBreak(styles[e.styleId ?? 0].block.breakBefore),
        ) ||
        oldPageBreaks.any((anchor) => anchor > image && anchor <= title)) {
      continue;
    }
    (result ??= starts.toList())[position] = image;
  }
  return result ?? starts;
}

bool _forcedPageBreak(String? value) => value == 'page' || value == 'always';

List<int> _confirmedStarts(
  ChapterContent content,
  List<TocTitleRef> titles,
  List<dynamic> explicit,
  Map<String, double?>? positions,
) {
  final wanted = <String, List<TocTitleRef>>{};
  for (final title in titles) {
    if (_frontMatter.hasMatch(title.title.trim())) continue;
    (wanted[_titleKey(title.title)] ??= []).add(title);
  }
  if (wanted.isEmpty) return const [];

  final blocks = content.blocks;
  final total = content.textLength;
  final anchoredOffsets = {
    for (final title in titles)
      if (positions?[title.anchorId] case final fraction?)
        (fraction * total).round(),
  }.toList()..sort();
  final anchoredChapters = <int>{};
  final matches = <TocTitleRef, List<({int index, int rank})>>{};
  var offset = 0, anchorIndex = 0;
  var sawText = false;
  var hasBodyText = false;
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    final start = offset;
    offset += block.textLength;
    final quote = block.kind == BlockKind.quote;
    if (block.kind != BlockKind.paragraph &&
        block.kind != BlockKind.heading &&
        !quote) {
      if (block.runLength > 0 &&
          (block.kind == BlockKind.listItem ||
              block.kind == BlockKind.codeBlock)) {
        sawText = hasBodyText = true;
      }
      continue;
    }
    // 目录标题很短。跳过长正文段，避免为目录匹配反复复制整段文字。
    final text = block.runLength <= 240 ? blockTextOf(block).trim() : '';
    final atStart = !sawText;
    if (block.runLength > 0 && (text.isNotEmpty || block.runLength > 240)) {
      sawText = true;
    }
    if (block.kind == BlockKind.paragraph &&
        (block.runLength > 240 ||
            (text.isNotEmpty && !wanted.containsKey(_titleKey(text))))) {
      hasBodyText = true;
    }
    if (quote ||
        (block.kind == BlockKind.paragraph &&
            _prefixedChapterTitle.hasMatch(text))) {
      // 引用和带「正文」或卷名的普通段落只按同名目录和精确锚点核实，
      // 避免把同名引文、目录导航或正文里的小标题当作章首。
      final names = text.isEmpty ? null : wanted[_titleKey(text)];
      if (names == null ||
          text.length > 96 ||
          block.runs.any((run) => run.link != null || run.footnote) ||
          explicit.any((range) => i >= range.first && i <= range.last)) {
        hasBodyText |= block.runLength > 0;
        continue;
      }
      var verified = false;
      for (final title in names) {
        final fraction = positions?[title.anchorId];
        if (fraction == null) continue;
        final target = (fraction * total).round();
        if (target < start - 8 || target >= offset) continue;
        (matches[title] ??= []).add((index: i, rank: 0));
        verified = true;
      }
      hasBodyText |= !verified && block.runLength > 0;
      continue;
    }
    if (text.isEmpty) continue;
    final numbered = _chapterNumber.hasMatch(text);
    final heading = block.kind == BlockKind.heading;
    if (!numbered && !heading && !atStart) continue;
    // 有些 MOBI 将一整卷的目录标题写成同名，实际锚点仍紧贴不同的正文回目。
    // 只接受紧邻锚点的独立编号标题，正文中的句子、目录链接和空锚点不另起双页。
    while (anchorIndex < anchoredOffsets.length &&
        anchoredOffsets[anchorIndex] < start - 8) {
      anchorIndex++;
    }
    if (anchorIndex < anchoredOffsets.length &&
        anchoredOffsets[anchorIndex] <= start + 8 &&
        text.length <= 96 &&
        _numberedTitle.hasMatch(text) &&
        block.runs.every((run) => run.link == null) &&
        i + 1 < blocks.length &&
        !explicit.any((r) => i >= r.first && i <= r.last)) {
      anchoredChapters.add(i);
    }
    final exact = _titleKey(text);
    final names =
        wanted[exact] ??
        (heading ? wanted[_titleKey(tocHeadingWithoutNumber(text))] : null);
    if (names == null) continue;
    // 显式章节里的小标题即便也出现在目录里，仍是该章的一部分。
    if (explicit.any((range) => i >= range.first && i <= range.last)) continue;
    for (final title in names) {
      final fragment = title.anchorId;
      final fraction = positions?[fragment];
      if (fragment == null || fragment.isEmpty) {
        if (!atStart) continue;
      } else if (fraction != null) {
        // 原书锚点可在标题前的容器，也可能落在同名标题之外的正文。
        final target = (fraction * total).round();
        if (target < start - 32 || target > offset) continue;
      } else if (!(numbered || (heading && atStart))) {
        continue;
      }
      (matches[title] ??= []).add((
        index: i,
        rank: numbered || !heading ? 0 : block.level ?? 6,
      ));
    }
  }
  if (!hasBodyText) return const [];
  final unique = matches.values
      .where((entries) => entries.length == 1)
      .map((entries) => entries.single)
      .toList();
  if (unique.isEmpty) return anchoredChapters.toList();
  final shallowest = unique
      .map((match) => match.rank)
      .reduce((a, b) => a < b ? a : b);
  return {
    ...anchoredChapters,
    for (final match in unique)
      if (match.rank == shallowest) match.index,
  }.toList()..sort();
}
