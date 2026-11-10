/// EPUB HTML5 解析、正文转换和精确统计由 Rust 生成，Dart 接回既有正文模型。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:direct_read_rust/direct_read_rust.dart';
import 'package:html/dom.dart';

import '../../../core/diagnostics/import_timing.dart';
import '../../../core/diagnostics/reader_work_trace.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/models/content_table.dart';
import '../../../domain/services/toc_entry_index.dart';
import 'toc_anchor_metadata.dart';
import 'dom_text_map.dart';
import 'epub_archive.dart';
import 'book_styles.dart';
import 'style_references.dart';
import 'xhtml_models.dart';
export 'xhtml_models.dart';
export 'style_references.dart';
export 'book_styles.dart';

class XhtmlBlockBuilder {
  XhtmlBlockBuilder({
    required this.basePath,
    required this.resolveImage,
    this.importTiming,
    this.styles,
    this.styleResolver,
    this.styleTextResolver,
    this.cssFiles = const {},
    bool buildTextMap = true,
    this.statisticsOnly = false,
  }) : buildTextMap = buildTextMap && !statisticsOnly;
  final String basePath;
  final ImageResolver resolveImage;
  final ImportTiming? importTiming;

  /// 全书样式表（可选）；为空时只读本章引用的样式。
  final BookStyles? styles;

  /// 按章节里 `<link rel="stylesheet">` 的绝对路径取样式（可选）。
  final BookStyles? Function(String entryPath)? styleResolver;

  /// 统一 CSS 路径：按归档条目取原始 CSS 文本（可选）。
  ///
  /// 和 [styleResolver] 二选一：传入它时，Rust 负责语法、选择器、层叠和继承，
  /// Dart 不再解析 CSS；没有它则继续走旧白名单（旧缓存/测试）。
  final String? Function(String entryPath)? styleTextResolver;

  /// 书内全部 CSS 文本（键是归档条目路径），供 Rust 在规则原位置展开 `@import`。
  final Map<String, String> cssFiles;
  final bool buildTextMap, statisticsOnly;
  Document? _document;
  Document? get document => _document;
  static const warningStylesheet = '部分排版样式已忽略';
  static const warningTable = '表格已简化，仅保留文字与图片';
  XhtmlBlocks convert(String source) =>
      _convert(source, () => NativeHtml(source));

  /// 原书字节直接进入 Rust；资源路径和正文模型仍由原来的规则处理。
  ///
  /// 这里额外解码一份字符串，只为找出本章引用的样式文件与内联 `<style>`；
  /// 正文本身仍以原始字节交给 Rust。
  XhtmlBlocks convertBytes(Uint8List source) => _convert(
    utf8.decode(source, allowMalformed: true),
    () => NativeHtml.bytes(source),
  );

  /// 本章实际使用的样式（全书 + 本章引用的文件 + 内联 `<style>`）。
  ///
  /// 统计、导入和读章三条路径必须用同一份结果，否则颜色／字号切出的 run 边界
  /// 会让首尾空白裁剪结果不同，正文长度就对不上。
  static BookStyles resolveChapterStyles({
    required String basePath,
    String? source,
    BookStyles? bookStyles,
    BookStyles? Function(String entryPath)? styleResolver,
  }) {
    final sheets = <BookStyles>[];
    if (bookStyles != null && !bookStyles.isEmpty) sheets.add(bookStyles);
    if (source != null) {
      for (final href in linkedStyleSheets(source)) {
        final entry = resolveEntryPath(basePath, href);
        if (entry == null) continue;
        final sheet = styleResolver?.call(entry);
        if (sheet != null && !sheet.isEmpty) sheets.add(sheet);
      }
      for (final css in inlineStyleBlocks(source)) {
        final sheet = BookStyles.parse({'inline.css': css});
        if (!sheet.isEmpty) sheets.add(sheet);
      }
    }
    return sheets.isEmpty ? BookStyles.none : BookStyles.combine(sheets);
  }

  BookStyles _resolveStyles(String? source) => resolveChapterStyles(
    basePath: basePath,
    source: source,
    bookStyles: styles,
    styleResolver: styleResolver,
  );

  /// 按 HTML 里 `<link>`／`<style>` 的真实顺序读出全部原始 CSS。
  ///
  /// 外链文本同时放进 [cssFiles]，让 Rust 在规则原位置展开 `@import`；调用方
  /// 还可以额外提供书内其它 CSS（导入/读章时从归档列一次）。
  ({List<Map<String, Object>> sources, Map<String, String> files})
  _resolveCssSources(List<dynamic> tags) {
    String? resolver(String path) =>
        cssFiles[path] ?? styleTextResolver?.call(path);
    final files = Map<String, String>.from(cssFiles);
    final sources = <Map<String, Object>>[];
    final seenImports = <String>{};
    void addImports(String path, String text) {
      // 只递归读取本章真正会展开的 @import，不把全书 CSS 都塞进每次转换的元数据。
      for (final match in RegExp(
        r'''@import\s+(?:url\(\s*)?["']?([^"')\s;]+)''',
        caseSensitive: false,
      ).allMatches(text)) {
        final entry = resolveEntryPath(path, match.group(1)!);
        if (entry == null || !seenImports.add(entry)) continue;
        final imported = resolver(entry);
        if (imported == null) continue;
        files[entry] = imported;
        addImports(entry, imported);
      }
    }

    for (final raw in tags) {
      final tag = (raw as Map).cast<String, dynamic>();
      final value = tag['value'] as String;
      final media = (tag['media'] as String? ?? '').trim();
      String conditioned(String text) =>
          media.isEmpty ? text : '@media $media {$text}';
      if (tag['inline'] == true) {
        if (value.trim().isEmpty) continue;
        sources.add({
          'path': basePath,
          'text': conditioned(value),
          'inline': true,
        });
        addImports(basePath, value);
      } else {
        final entry = resolveEntryPath(basePath, value);
        if (entry == null) continue;
        final text = resolver(entry);
        if (text == null) continue;
        files[entry] = text;
        sources.add({
          'path': entry,
          'text': conditioned(text),
          'inline': false,
        });
        addImports(entry, text);
      }
    }
    return (sources: sources, files: files);
  }

  /// TOC-only source mapping. Keep the full DOM and source pieces native and
  /// transfer only target blocks; grapheme snapping remains the Locator rule.
  static Map<String, double?>? anchorPositions(
    String source,
    String basePath,
    Iterable<String> fragments,
  ) {
    final wanted = anchorCandidates(fragments);
    final native = NativeHtml(source);
    try {
      final metadata = _metadata(
        native.references,
        basePath,
        (entry) => ResolvedImage(resourcePath: entry, width: 0, height: 0),
      );
      final data = native.anchorPositions({
        ...metadata,
        'anchors': wanted.toList(),
      });
      return decodeAnchorPositions(data, fragments);
    } finally {
      native.close();
    }
  }

  XhtmlBlocks _convert(String? source, NativeHtml Function() open) {
    // 只在性能包细分按需正文转换，避免把图片提取、原生转换和Dart模型
    // 都误称为HTML解析；这些阶段包含在上层content.worker内，不能重复相加。
    final trace = ReaderWorkTrace.start('content.xhtml.convert', {
      'textMap': buildTextMap,
      'statisticsOnly': statisticsOnly,
    });
    final NativeHtml native;
    try {
      native = importTiming?.detail('html_dom_parse', open) ?? open();
      trace?.mark('native_parse');
    } catch (error) {
      trace?.finish(status: error.runtimeType.toString());
      rethrow;
    }
    try {
      final references = native.references;
      trace?.mark('native_references');
      if (trace != null) {
        trace.details['imageRefs'] = (references['images'] as List).length;
        trace.details['linkRefs'] = (references['links'] as List).length;
      }
      final metadata = _metadata(references, basePath, resolveImage);
      metadata['documentPath'] = basePath;
      // 统一 CSS：Dart 只按文档顺序读出原始字节，语法、匹配、层叠、继承都在 Rust。
      if (!statisticsOnly &&
          (styleTextResolver != null ||
              (styles == null && styleResolver == null))) {
        final resolved = _resolveCssSources(
          references['css'] as List? ?? const [],
        );
        if (resolved.sources.isNotEmpty) {
          metadata['cssSources'] = resolved.sources;
          metadata['cssFiles'] = resolved.files;
        }
      } else {
        // 旧白名单路径：只给没有统一来源的旧缓存/测试使用。
        final bookStyles = statisticsOnly
            ? BookStyles.none
            : _resolveStyles(source);
        if (!bookStyles.isEmpty) metadata['styles'] = bookStyles.toJson();
      }
      if (!statisticsOnly) {
        metadata['displaySource'] = true;
        // 正式路径（没有旧 styles／styleResolver）一律走统一引擎；只有测试或
        // 极旧缓存仍显式传旧表时才保留旧匹配。这样生产里不会再落到 Rust
        // `styles.rs` 的 Props 路径。
        final legacy = styles != null || styleResolver != null;
        if (styleTextResolver != null || !legacy) {
          metadata['unifiedCss'] = true;
        }
      }
      trace?.mark('resolve_resources');
      Map<String, dynamic> convert() => native.convert(
        metadata,
        statisticsOnly: statisticsOnly,
        buildTextMap: buildTextMap,
      );
      final result =
          importTiming?.detail('blocks_and_text_map', convert) ?? convert();
      trace?.mark('native_convert_and_transfer');
      DomTextMap? textMap;
      if (buildTextMap) {
        final nodes = <int, Node>{};
        final document = Document();
        Node decode(List<dynamic> data) {
          final tag = data[1] as String;
          final Node node = data[0] == 0
              ? document
              : tag.isNotEmpty
              ? document.createElementNS(data[6] as String?, tag)
              : data[3] == true
              ? Comment(data[2] as String)
              : Text(data[2] as String);
          nodes[data[0] as int] = node;
          if (node is Element) {
            node.attributes.addAll((data[4] as Map).cast<String, String>());
          }
          for (final child in data[5] as List) {
            node.nodes.add(decode(child as List));
          }
          return node;
        }

        decode(result['dom'] as List);
        _document = document;
        final builder = DomTextMapBuilder();
        final blocks = (result['blocks'] as List)
            .map(
              (b) => ContentBlock.fromJson((b as Map).cast<String, Object?>()),
            )
            .toList();
        final byId = {for (final b in blocks) b.id: b};
        for (final entry in result['pieces'] as List) {
          final id = entry[0] as String;
          builder.addBlock(
            id,
            byId[id]!.runs.map((r) => r.text).join(),
            [
              for (final p in entry[1] as List)
                SourcePiece(
                  node: p[0] == null ? null : nodes[p[0]] as Text,
                  raw: p[1] as String,
                  runIndex: p[2] as int,
                  displayBreaks: (p[3] as List).cast<int>(),
                ),
            ],
            keepTrailingRuns: entry.length > 2
                ? (entry[2] as List).cast<int>().toSet()
                : const {},
          );
        }
        textMap = builder.build();
      }
      trace?.mark('text_map');
      final converted = _result(result, statisticsOnly, textMap: textMap);
      trace?.mark('dart_models');
      return converted;
    } catch (error) {
      trace?.finish(status: error.runtimeType.toString());
      rethrow;
    } finally {
      native.close();
      trace?.finish();
    }
  }

  /// 只批量做目录所需的精确统计；最多四个工作线程，顺序由输入决定。
  static List<XhtmlBlocks> statisticsBatch(
    List<String> sources,
    List<String> paths,
    ImageResolver resolver, {
    ImportTiming? timing,
    List<Uint8List>? rawSources,
    bool statisticsOnly = true,
    Map<String, List<String>> tocFragments = const {},
    Map<String, Map<String, double?>>? tocPositions,
    Map<String, Map<String, double>>? tocHeadings,

    /// 每章实际使用的样式（可选）。颜色／字号只影响显示、不改变正文长度，
    /// 统计默认不需要；保留参数供需要统计块样式的场景使用。
    Map<String, BookStyles> stylesByPath = const {},
  }) {
    NativeHtmlBatch open() => rawSources == null
        ? NativeHtmlBatch(sources)
        : NativeHtmlBatch.bytes(rawSources);
    final batch = timing?.detail('native_html_parse_batch', open) ?? open();
    try {
      final refs =
          timing?.detail(
            'native_references_transfer',
            () => batch.references,
          ) ??
          batch.references;
      List<Map<String, Object>> metadata() => [
        for (var i = 0; i < paths.length; i++)
          _metadata(
            (refs[i] as Map).cast<String, dynamic>(),
            paths[i],
            resolver,
          ),
      ];
      final input = timing?.detail('resource_metadata', metadata) ?? metadata();
      for (var i = 0; i < paths.length; i++) {
        final fragments = tocFragments[paths[i]];
        if (fragments != null && fragments.isNotEmpty) {
          input[i]['anchors'] = anchorCandidates(fragments).toList();
        }
        final styles = stylesByPath[paths[i]];
        if (styles != null && !styles.isEmpty) {
          input[i]['styles'] = styles.toJson();
        }
      }
      final results =
          timing?.detail(
            'native_statistics_transfer',
            () => batch.convert(input, statisticsOnly: statisticsOnly),
          ) ??
          batch.convert(input, statisticsOnly: statisticsOnly);
      for (var i = 0; i < paths.length; i++) {
        final raw = (results[i] as Map)['tocPositions'];
        if (raw == null) continue;
        final positions = decodeAnchorPositions(
          (raw as Map).cast<String, dynamic>(),
          tocFragments[paths[i]]!,
        );
        if (positions != null) tocPositions?[paths[i]] = positions;
        final converted = results[i] as Map;
        final length = converted['length'] as int;
        final headings = <String, double>{};
        for (final heading in converted['tocHeadings'] as List? ?? []) {
          final text = (heading[0] as String).trim();
          final fraction = length == 0 ? 0.0 : (heading[1] as int) / length;
          headings.putIfAbsent(text, () => fraction);
          headings.putIfAbsent(tocHeadingWithoutNumber(text), () => fraction);
        }
        // An empty map also proves that the complete standard chapter contains
        // no matching heading; do not reread it to repeat a known failed lookup.
        tocHeadings?[paths[i]] = headings;
      }
      return [
        for (final result in results)
          // 即使为位置匹配返回正文块，目录统计仍使用原生统计口径。
          _result((result as Map).cast<String, dynamic>(), true),
      ];
    } finally {
      if (timing != null) {
        for (final entry in batch.timings.entries) {
          if (entry.key.endsWith('_bytes')) {
            timing.count(entry.key, entry.value as int);
          } else {
            timing.recordDetail(entry.key, entry.value as int);
          }
        }
      }
      batch.close();
    }
  }
}

Map<String, Object> _metadata(
  Map<String, dynamic> refs,
  String base,
  ImageResolver resolve,
) {
  final images = <String, Object>{}, links = <String, Object>{};
  for (final src in refs['images'] as List) {
    if (images.containsKey(src)) continue;
    final path = resolveEntryPath(base, src as String);
    final image = path == null ? null : resolve(path);
    if (image != null) {
      images[src] = {
        'resource': image.resourcePath,
        'width': image.width,
        'height': image.height,
      };
    }
  }
  for (final href in refs['links'] as List) {
    // 锚点写在路径里会让 resolveEntryPath 把 '#frag' 当成文件名的一部分，
    // 这里只解析文件部分；锚点由转换器从 href 里单独取。
    final raw = href as String;
    final hash = raw.indexOf('#');
    final file = hash < 0 ? raw : raw.substring(0, hash);
    // 只有锚点（`#fn1`）时目标就是本章
    final path = file.isEmpty ? base : resolveEntryPath(base, file);
    if (path != null) links[href] = path;
  }
  return {'images': images, 'links': links};
}

XhtmlBlocks _result(
  Map<String, dynamic> result,
  bool stats, {
  DomTextMap? textMap,
}) {
  var heading = result['heading'] as String?;
  if (heading != null && heading.length > 60) {
    heading = heading.substring(0, 60);
  }
  return XhtmlBlocks(
    blocks: [
      for (final b in result['blocks'] as List)
        ContentBlock.fromJson((b as Map).cast<String, Object?>()),
    ],
    headingTitle: heading,
    warnings: (result['warnings'] as List).cast<String>().toSet(),
    textMap: textMap,
    tables: [
      for (final t in result['tables'] as List)
        ContentTable.fromJson((t as Map).cast<String, dynamic>()),
    ],
    statisticsLength: stats ? result['length'] as int : null,
    statisticsSingleImage: result['singleImage'] as String?,
    // Rust 在转换时算好的样式表（批次 C）；统计路径不带它。
    stylesJson: result['styles'] is Map
        ? (result['styles'] as Map).cast<String, Object?>()
        : null,
    displaySourceJson: result['displaySource'] is Map
        ? (result['displaySource'] as Map).cast<String, Object?>()
        : null,
  );
}
