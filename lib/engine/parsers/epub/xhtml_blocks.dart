/// EPUB HTML5 解析、正文转换和精确统计由 Rust 生成，Dart 接回既有正文模型。
library;

import 'dart:typed_data';

import 'package:direct_read_rust/direct_read_rust.dart';
import 'package:html/dom.dart';

import '../../../core/diagnostics/import_timing.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/models/content_table.dart';
import 'dom_text_map.dart';
import 'epub_archive.dart';
import 'xhtml_models.dart';
export 'xhtml_models.dart';

class XhtmlBlockBuilder {
  XhtmlBlockBuilder({
    required this.basePath,
    required this.resolveImage,
    this.importTiming,
    bool buildTextMap = true,
    this.statisticsOnly = false,
  }) : buildTextMap = buildTextMap && !statisticsOnly;
  final String basePath;
  final ImageResolver resolveImage;
  final ImportTiming? importTiming;
  final bool buildTextMap, statisticsOnly;
  Document? _document;
  Document? get document => _document;
  static const warningStylesheet = '部分排版样式已忽略';
  static const warningTable = '表格已简化，仅保留文字与图片';
  XhtmlBlocks convert(String source) => _convert(() => NativeHtml(source));

  /// 原书字节直接进入 Rust；资源路径和正文模型仍由原来的规则处理。
  XhtmlBlocks convertBytes(Uint8List source) =>
      _convert(() => NativeHtml.bytes(source));

  XhtmlBlocks _convert(NativeHtml Function() open) {
    final native = importTiming?.detail('html_dom_parse', open) ?? open();
    try {
      final metadata = _metadata(native.references, basePath, resolveImage);
      Map<String, dynamic> convert() => native.convert(
        metadata,
        statisticsOnly: statisticsOnly,
        buildTextMap: buildTextMap,
      );
      final result =
          importTiming?.detail('blocks_and_text_map', convert) ?? convert();
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
          builder.addBlock(id, byId[id]!.runs.map((r) => r.text).join(), [
            for (final p in entry[1] as List)
              SourcePiece(
                node: p[0] == null ? null : nodes[p[0]] as Text,
                raw: p[1] as String,
                runIndex: p[2] as int,
                displayBreaks: (p[3] as List).cast<int>(),
              ),
          ]);
        }
        textMap = builder.build();
      }
      return _result(result, statisticsOnly, textMap: textMap);
    } finally {
      native.close();
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
      final results =
          timing?.detail(
            'native_statistics_transfer',
            () => batch.convert(input, statisticsOnly: statisticsOnly),
          ) ??
          batch.convert(input, statisticsOnly: statisticsOnly);
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
    final path = resolveEntryPath(base, href as String);
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
  );
}
